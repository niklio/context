// Context distillation harness — hot-reloaded from context.nikliolios.com/harness.js
// Sandboxed in the app's JavaScriptCore runtime: capabilities are host.* (local
// corpus), llm.* (local model), ui.* (progress), log().
//
// v9: split evidence passes (relationship vs persona+events), qualitative-only
// cards with a fixed viewpoint, roster scored by volume×recency with evidence
// gates, deterministic role hints (surname, contact decorations, owner name),
// business lexicon, lenient event dates. Numbers live in code, never in prose.
const HARNESS_VERSION = 10;

const CAPS = {
  persons: 18,
  groups: 4,
  businesses: 12,
  relationshipChars: 8000,
  personaChars: 12000,
  evidenceChars: 900,
  obsPerTag: 40,
  timelineBatchChars: 9000,
  parallel: 4,
  minSignalsForCard: 2,
  roleBatch: 12,
};

const OWNER = (typeof __owner !== "undefined") ? JSON.parse(__owner()) : { name: "" };

const TAXONOMY_LIST = [
  "Spouse", "Wife", "Husband", "Partner", "Girlfriend", "Boyfriend", "Mother",
  "Father", "Sibling", "Brother", "Sister", "Child", "Grandparent",
  "Extended family", "In-law", "Close friend", "Friend", "Roommate", "Manager",
  "Direct report", "Colleague", "Client", "Service provider", "Acquaintance",
];
const TAXONOMY = TAXONOMY_LIST.join(", ") + ", unclear";

const SECTIONS = [
  ["ABOUT", "About me"],
  ["COMM", "Communication & voice"],
  ["WORK", "Work & projects"],
  ["INTERESTS", "Interests & tastes"],
  ["HEALTH", "Health & fitness"],
  ["DAILY", "Daily life & logistics"],
  ["DATES", "Dates & events"],
  ["VALUES", "Values & opinions"],
  ["ASSIST", "Working with me"],
];
const VALID_TAGS = new Set(SECTIONS.map((s) => s[0]));

const BUSINESS_RX = new RegExp(
  "\\b(air ?lines?|airways|bank|pharmacy|cvs|walgreens|rite aid|fedex|ups|usps|" +
  "amazon|uber|lyft|doordash|grubhub|seamless|instacart|dental|dentist|clinic|" +
  "medical|salon|spa|insurance|verizon|at&t|t.?mobile|xfinity|comcast|spectrum|" +
  "chase|amex|american express|citi|capital one|wells fargo|delta|united|jetblue|" +
  "southwest|alaska air|marriott|hilton|hyatt|airbnb|resy|opentable|equinox|" +
  "no.?reply|alert|notification|support|customer|service|store|shop|pizza|" +
  "cleaners|laundry|barber)\\b", "i");

// ---------------------------------------------------------------- helpers

let llmErrors = 0, llmCalls = 0, firstLlmError = null;
let llmFactsStarted = false;   // once true, raw stats never appear again
function llmFact(text) { llmFactsStarted = true; ui.fact(text); }
function gen(prompt, model) {
  llmCalls++;
  const out = llm.generate(prompt, model) || "";
  if (out.startsWith("__ERROR__") || out === "") {
    llmErrors++;
    if (!firstLlmError && out) firstLlmError = out.slice(0, 200);
    return "";
  }
  return out;
}
function genParallel(prompts, model, concurrency) {
  llmCalls += prompts.length;
  const outs = llm.generateParallel(prompts, model, concurrency);
  return outs.map((o) => {
    o = o || "";
    if (o.startsWith("__ERROR__") || o === "") {
      llmErrors++;
      if (!firstLlmError && o) firstLlmError = o.slice(0, 200);
      return "";
    }
    return o;
  });
}
function assertLlmHealthy(stage) {
  if (llmCalls >= 4 && llmErrors / llmCalls > 0.5) {
    throw new Error(`local model failing at stage "${stage}" (${llmErrors}/${llmCalls} calls failed): ${firstLlmError || "empty responses"}`);
  }
}

function normalizeName(n) {
  const cleaned = n.replace(/[^\p{L}\p{N} .,'\-&()+@_]/gu, "").replace(/\s+/g, " ").trim();
  return cleaned || n;
}

function isFiller(s) {
  const l = s.toLowerCase();
  return l.includes("no observation") || l.includes("n/a") ||
    l.includes("insufficient") || l.includes("not enough evidence") ||
    l.includes("nothing to conclude");
}
function isTemplate(s) { return s.includes("[") && s.includes("]"); }

// Cards are qualitative; any bullet that recites stats or verbalizes the
// taxonomy's escape hatch gets struck. The numbers live in code.
function isStatBullet(s) {
  if (/unclear/i.test(s)) return true;
  if (/\d+\s*(message|msg|%|percent|days?\b|weeks?\b|months?\b|years?\b|per week)/i.test(s)) return true;
  if (/last (contact|interaction|communication|message)/i.test(s)) return true;
  if (/\b(initiat|respond to|exchange[ds]?|averag)\w*\s+(approximately|roughly|around|about)?\s*\d/i.test(s)) return true;
  return false;
}

function dedupe(items) {
  const seen = new Set();
  return items.filter((b) => {
    const k = b.toLowerCase().replace(/[.,;:!?]+$/, "");
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

const MONTHS = { jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
                 jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12" };
function normDate(d) {
  d = d.trim().replace(/[,.]$/, "");
  let m = d.match(/^((19|20)\d{2})[-\/](0?[1-9]|1[0-2])([-\/](0?[1-9]|[12]\d|3[01]))?$/);
  if (m) {
    const mm = m[3].padStart(2, "0");
    return m[5] ? `${m[1]}-${mm}-${m[5].padStart(2, "0")}` : `${m[1]}-${mm}`;
  }
  m = d.match(/^([A-Za-z]{3,9})\.?\s+((19|20)\d{2})$/);
  if (m) {
    const mm = MONTHS[m[1].slice(0, 3).toLowerCase()];
    if (mm) return `${m[2]}-${mm}`;
  }
  m = d.match(/^((19|20)\d{2})$/);
  return m ? m[1] : null;
}

function parseEvidence(output, source) {
  const signals = [], obs = [], events = [];
  for (let raw of output.split("\n")) {
    let line = raw.trim().replace(/^[-•*]+\s*/, "").replace(/\*\*/g, "").trim();
    const m = line.match(/^(OBS|SIGNAL|HYPOTHESIS|EVENT)\s*[:\-–]\s*(.*)$/i);
    if (!m) continue;
    const kind = m[1].toUpperCase();
    const body = m[2].trim();
    if (kind === "SIGNAL" && body.length > 8) signals.push(body);
    else if (kind === "HYPOTHESIS" && body.length > 8) signals.push("hypothesis: " + body);
    else if (kind === "EVENT") {
      const parts = body.split("|").map((p) => p.trim());
      if (parts.length >= 2 && parts[1].length > 6) {
        const date = normDate(parts[0]);
        if (date) {
          events.push({ date, text: parts[1], source,
            explicit: parts.length > 2 && parts[2].toLowerCase().includes("explicit") });
        }
      }
    } else if (kind === "OBS") {
      const parts = body.split("|").map((p) => p.trim());
      let tag = null, text = null, explicit = false;
      if (parts.length >= 3) {
        tag = parts[0]; text = parts.slice(2).join(" | ");
        explicit = parts[1].toLowerCase().includes("explicit");
      } else if (parts.length === 2) { tag = parts[0]; text = parts[1]; }
      if (tag && text) {
        tag = tag.toUpperCase().replace(/[^A-Z]/g, "");
        if (VALID_TAGS.has(tag) && text.length > 8 && !isFiller(text) && !isTemplate(text)) {
          obs.push({ tag, text, source, explicit });
        }
      }
    }
  }
  return { signals, obs, events };
}

function parseTagged(output, validTags) {
  const results = [];
  for (let raw of output.split("\n")) {
    let line = raw.trim();
    if (line.startsWith("- ")) line = line.slice(2);
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const tag = line.slice(0, colon).trim().toUpperCase().replace(/[^A-Z]/g, "");
    const body = line.slice(colon + 1).trim();
    if (validTags.has(tag) && body.length > 8 && !isFiller(body) && !isTemplate(body)) {
      results.push([tag, body]);
    }
  }
  return results;
}

function statFact(c) {
  const s = c.stats;
  const name = normalizeName(c.name);
  const opts = [];
  if (s.spanDays > 365) {
    opts.push(`${c.messageCount.toLocaleString()} messages with ${name} across ${(s.spanDays / 365).toFixed(1)} years`);
  } else if (c.messageCount > 50) {
    opts.push(`${c.messageCount.toLocaleString()} messages with ${name}`);
  }
  if (s.myInitiationShare >= 0.65) {
    opts.push(`You start ${Math.round(s.myInitiationShare * 100)}% of your conversations with ${name}`);
  } else if (s.myInitiationShare <= 0.35 && c.messageCount > 30) {
    opts.push(`${name} usually texts you first`);
  }
  if (s.perWeek >= 20) {
    opts.push(`You and ${name} trade ${Math.round(s.perWeek)} messages a week`);
  }
  return opts.length ? opts[c.id % opts.length] : null;
}

function roleHints(c) {
  const hints = [];
  const ownerLast = (OWNER.name || "").trim().split(/\s+/).pop() || "";
  if (ownerLast.length > 2 &&
      normalizeName(c.name).toLowerCase().includes(ownerLast.toLowerCase())) {
    hints.push("shares your last name — likely family");
  }
  if (/[❤♥\u{1F495}-\u{1F49F}\u{1FA77}]/u.test(c.name)) {
    hints.push("saved in your contacts with hearts — strong partner signal");
  }
  if (c.stats.perWeek >= 60) hints.push("one of your highest-frequency contacts");
  return hints;
}

// ---------------------------------------------------------------- prompts

const NO_CONCLUSIONS =
  "You are gathering EVIDENCE from one conversation in my message history. This " +
  "runs locally at my request. You see ONLY this conversation, so do not draw " +
  "conclusions that require seeing my other relationships: NO role verdicts, NO " +
  'superlatives ("closest", "best friend", "favorite"), NO "always/never" claims. ' +
  "Evidence only — a later stage that sees everything will judge.";

function relationshipEvidencePrompt(chat, transcript) {
  return `${NO_CONCLUSIONS}

Conversation with ${normalizeName(chat.name)}${chat.isGroup ? " (group chat)" : ""}. Gather relationship evidence — the CONTENT of the relationship, not statistics:

SIGNAL: <one concrete piece of evidence: how we address each other ("mom", "babe", pet names), topics we discuss (wedding planning, kids' schedules, work projects, training runs), events we've shared (dinners, trips, races), emotional register (venting, jokes, advice), logistics we coordinate (same home, family gatherings)>
HYPOTHESIS: <a possible relationship role from: ${TAXONOMY}> — <the evidence for it> (several allowed; uncertainty fine)

Output 5-12 SIGNAL lines and 1-3 HYPOTHESIS lines, nothing else. Quote short phrases as evidence where helpful.

TRANSCRIPT:
${transcript}`;
}

function personaEventsPrompt(chat, transcript) {
  const who = normalizeName(chat.name);
  const isBiz = chat.kind === "business" || chat.kind === "automated";
  return `${NO_CONCLUSIONS}

${isBiz ? `This is a business/automated sender ("${who}") — extract what it reveals about Me (travel, purchases, appointments, habits).` : `Conversation with ${who}.`}

Extract observations about Me and real-world events from my life:

OBS: <TAG> | <explicit or inferred> | <complete sentence about Me>
Tags: ABOUT (name, job, employer, city, life stage), COMM (how I write here), WORK, INTERESTS, HEALTH, DAILY, DATES (upcoming), VALUES, ASSIST (what I ask for help with).

EVENT: <date> | <what happened> | <explicit or inferred>
Events are things that HAPPENED in my life: meetups, dinners, trips, races, moves, milestones, weddings, job changes — small or big. Date them from the [YYYY-MM-DD] message timestamps ("yesterday"/"last Saturday" resolve relative to that message's date). Use YYYY-MM-DD when known, else YYYY-MM, else YYYY.

Output ONLY OBS and EVENT lines. Specifics beat generalities.

TRANSCRIPT:
${transcript}`;
}

function rolesPrompt(entries) {
  return `You can now see ALL of my personal relationships at once — the only vantage point from which comparative judgments are legitimate. For each person, using their gathered evidence, deterministic hints, and stats (and comparing across people), assign the most specific relationship role the evidence supports.

Taxonomy: ${TAXONOMY}

Rules:
- Prefer "unclear" over guessing when evidence is thin.
- Combine evidence: pet names + shared home + hearts in contact name → Partner or Spouse; Spouse only with marriage evidence.
- Deterministic hints (surnames, contact-name decorations) are strong evidence.
- Comparative calls are allowed HERE only: you may mark ONE person "closest friend" in the note if the whole picture clearly supports it; if several are close, note "one of my closest friends" instead.

Output exactly one line per person:
PERSON: <name> | <role from the taxonomy> | <optional short note>

${entries}`;
}

const SECTION_GUIDANCE = {
  ABOUT: "Triangulate identity: name from how people address me, job/city corroborated across conversations. Resolve contradictions by recency and say so ('moved from X to Y').",
  COMM: "Compare my style ACROSS audiences using the role graph — describe register shifts (partner vs colleagues vs friends), not one thread's tone.",
  WORK: "Separate corroborated facts (employer, role) from ambitions and side projects.",
  INTERESTS: "Tier: core interests (many conversations, long span, recent) vs current phase vs historical. Weigh breadth of audiences.",
  HEALTH: "Only durable patterns across time; skip one-off complaints.",
  DAILY: "Recurring routines and practical logistics only.",
  DATES: "Specific dates with what they are; recurring greetings imply birthdays/anniversaries.",
  VALUES: "High bar: explicit self-statements, or the same stance shown to at least two different people.",
  ASSIST: "Derive instructions an AI assistant should follow for me, from how I ask for things across all conversations.",
};

function personaPrompt(tags, roleGraph, observations) {
  const byTag = {};
  for (const o of observations) {
    if (tags.includes(o.tag)) (byTag[o.tag] = byTag[o.tag] || []).push(o);
  }
  const body = tags
    .filter((t) => byTag[t] && byTag[t].length)
    .map((t) => {
      const capped = byTag[t].slice(-CAPS.obsPerTag);
      return `${t} observations:\n` + capped.map(
        (o) => `- [${o.source}, ${o.explicit ? "explicit" : "inferred"}] ${o.text}`).join("\n");
    }).join("\n\n");

  return `You are synthesizing sections of my profile from observations gathered across ALL my conversations. ${OWNER.name ? `This Mac's account belongs to "${OWNER.name}" — almost certainly me; anchor identity on it.` : ""} You know who everyone is to me:

${roleGraph}

Section guidance (instructions for you — NEVER copy into output):
${tags.map((t) => `• ${t} — ${SECTION_GUIDANCE[t] || ""}`).join("\n")}

Write final profile bullets addressed to me in the second person ("You…"), each a complete sentence, in the form \`TAG: bullet\`. Facts seen across several conversations are load-bearing; one-off inferred items are droppable. A tag with too little evidence gets NO lines — never pad. Output ONLY conclusion lines.

${body}`;
}

function timelinePrompt(mentionList) {
  return `Below are mentions of real-world events from my life, gathered from different conversations, sorted by date. Merge into a clean chronological timeline:
- Mentions of the SAME event become ONE entry; if it appeared in 2+ distinct conversations, append " (corroborated in N conversations)".
- Keep small events (a breakfast, a ride) AND big ones (weddings, moves, job changes). Drop non-events and unresolved plans.
- One line per event: \`<date> — <event>\`, chronological. Nothing else.

${mentionList}`;
}

function cardPrompt(chat, role, note, evidence) {
  const name = normalizeName(chat.name);
  const roleKnown = role && role.toLowerCase() !== "unclear" && role !== "Group chat";
  return `Write the "${name}" entry for MY profile. The profile addresses ME as "you"; ${name} is described in the third person. ${roleKnown ? `A stage that compared all my relationships determined: ${name} is my ${role}${note ? ` (${note})` : ""}. Lead with that, stated naturally.` : `The relationship type is not established — do NOT speculate about it or mention uncertainty; just describe what the conversations show.`}

Example of the required style (for someone else's profile):
### Maya
- Maya is your sister — you two plan family holidays and swap updates about your parents.
- You send her running memes and she sends restaurant recommendations.
- She's your go-to for advice about your nephew's birthday gifts.

Evidence about my relationship with ${name}:
${evidence.join("; ").slice(0, 1600) || "(thin — write at most 2 short bullets)"}

Rules: 2-6 bullets, each starting "- ". ONLY qualitative content from the evidence — what we talk about, how we interact, shared history and plans, practical facts. NEVER use numbers, percentages, message counts, frequencies, or "last contact" phrasing — statistics are banned. No speculation, no placeholders, no superlatives beyond the given note. Output ONLY the bullets (no heading).
`;
}

function polishPrompt(section, roleGraph) {
  return `Below is the Relationships section of my profile plus the authoritative role assignments. Fix ONLY these problems, changing nothing else:
- superlatives not present in the assignments — soften them
- role contradictions with the assignments
Return the full corrected section otherwise verbatim, starting with the first ###.

ROLE ASSIGNMENTS:
${roleGraph}

SECTION:
${section}`;
}

// ---------------------------------------------------------------- pipeline

function distill() {
  log(`harness v${HARNESS_VERSION} starting (owner: ${OWNER.name || "unknown"})`);
  const all = host.chats();
  log(`runtime handed ${all.length} conversations`);
  if (!all.length) throw new Error("the runtime handed the harness 0 conversations");

  // ---- Stage 0: classification — lexicon beats saved-contact status -------
  let persons = [], businesses = [], ambiguous = [];
  const groupsAll = [];
  for (const c of all) {
    if (c.isGroup) { groupsAll.push(c); continue; }
    if (BUSINESS_RX.test(c.name) || BUSINESS_RX.test(c.identifier)) { businesses.push(c); continue; }
    if (c.kind === "person") persons.push(c);
    else if (c.kind === "business" || c.kind === "automated") businesses.push(c);
    else ambiguous.push(c);
  }
  if (ambiguous.length) {
    const listing = ambiguous.map((c, i) =>
      `${i + 1}. ${normalizeName(c.name)}: ${(c.sampleIncoming || []).join(" ⏐ ")}`).join("\n");
    const out = gen(`For each numbered sender below, decide if it is a real PERSON I know, or a BUSINESS/automated sender (store, bank, reminders, codes, deliveries). One line per number, exactly:\n<number>. PERSON  or  <number>. BUSINESS\n\n${listing}`);
    const verdicts = {};
    for (const line of out.split("\n")) {
      const m = line.match(/^\s*(\d+)\.\s*(PERSON|BUSINESS)/i);
      if (m) verdicts[parseInt(m[1], 10)] = m[2].toUpperCase();
    }
    ambiguous.forEach((c, i) => {
      (verdicts[i + 1] === "BUSINESS" ? businesses : persons).push(c);
    });
  }

  // ---- Stage 0b: roster — volume × recency, not raw volume ----------------
  const rosterScore = (c) => c.messageCount / (1 + c.stats.daysSinceLast / 90);
  persons = persons
    .filter((c) => c.messageCount >= 30 || c.stats.daysSinceLast < 60)
    .sort((a, b) => rosterScore(b) - rosterScore(a)).slice(0, CAPS.persons);
  const groups = groupsAll.sort((a, b) => rosterScore(b) - rosterScore(a)).slice(0, CAPS.groups);
  businesses = businesses.sort((a, b) => rosterScore(b) - rosterScore(a)).slice(0, CAPS.businesses);
  log(`roster: ${persons.length} persons, ${groups.length} groups, ${businesses.length} businesses (of ${all.length})`);

  const relJobs = [...persons, ...groups];
  const personaJobs = [...persons, ...groups, ...businesses];
  const totalUnits = relJobs.length + personaJobs.length + relJobs.length + 8;
  let completed = 0;
  const bump = () => ui.progress(++completed, totalUnits);

  // Raw stats exist ONLY to cover prefill latency at the very start.
  for (const headline of host.corpusHeadlines().slice(0, 3)) ui.fact(headline);
  let nuggets = 0;
  for (const c of persons) {
    const f = statFact(c);
    if (f) { ui.fact(f); if (++nuggets >= 3) break; }
  }

  // First taste: fast small call so an LLM insight lands in ~15s.
  const observations = [], eventMentions = [];
  if (persons.length) {
    const first = persons[0];
    const quick = gen(personaEventsPrompt(first,
      host.transcript(first.id, { maxChars: 2500 })));
    const taste = parseEvidence(quick, normalizeName(first.name));
    observations.push(...taste.obs);
    for (const o of taste.obs.slice(0, 2)) llmFact(o.text);
  }

  // ---- Stage 1a: relationship evidence (focused pass) ---------------------
  ui.status("Mapping your relationships…");
  const evidenceByName = {};
  for (let i = 0; i < relJobs.length; i += CAPS.parallel) {
    const batch = relJobs.slice(i, i + CAPS.parallel);
    if (!llmFactsStarted) {
      const c = batch.find((x) => statFact(x));
      if (c) ui.fact(statFact(c));
    }
    const outs = genParallel(batch.map((c) => relationshipEvidencePrompt(
      c, host.transcript(c.id, { maxChars: CAPS.relationshipChars }))), null, CAPS.parallel);
    let batchSignals = 0;
    batch.forEach((c, j) => {
      const { signals } = parseEvidence(outs[j] || "", normalizeName(c.name));
      evidenceByName[normalizeName(c.name)] = signals;
      batchSignals += signals.length;
      signals.filter((s) => !s.startsWith("hypothesis")).slice(0, 2)
        .forEach((s) => llmFact(s));
      bump();
    });
    log(`rel batch ${Math.floor(i / CAPS.parallel) + 1}: +${batchSignals} signals`);
    if (batchSignals === 0) log(`  sample: ${(outs[0] || "(empty)").slice(0, 300).replace(/\n/g, " ⏎ ")}`);
  }
  assertLlmHealthy("relationship evidence");

  // ---- Stage 1b: persona observations + events ----------------------------
  ui.status("Learning who you are…");
  for (let i = 0; i < personaJobs.length; i += CAPS.parallel) {
    const batch = personaJobs.slice(i, i + CAPS.parallel);
    const outs = genParallel(batch.map((c) => personaEventsPrompt(
      c, host.transcript(c.id, { maxChars: CAPS.personaChars }))), null, CAPS.parallel);
    let batchObs = 0, batchEvents = 0;
    batch.forEach((c, j) => {
      const { obs, events } = parseEvidence(outs[j] || "", normalizeName(c.name));
      observations.push(...obs);
      eventMentions.push(...events);
      batchObs += obs.length; batchEvents += events.length;
      obs.slice(0, 2).forEach((o) => llmFact(o.text));
      bump();
    });
    log(`persona batch ${Math.floor(i / CAPS.parallel) + 1}: +${batchObs} obs, +${batchEvents} events`);
    if (batchObs === 0 && batchEvents === 0) {
      log(`  sample: ${(outs[0] || "(empty)").slice(0, 300).replace(/\n/g, " ⏎ ")}`);
    }
  }
  log(`evidence totals: ${observations.length} obs, ${eventMentions.length} events, signals for ${Object.keys(evidenceByName).length}`);

  // ---- Stage 3: relationship synthesis (sees everyone, batched) -----------
  ui.status("Figuring out who's who…");
  const assignments = {};
  for (let i = 0; i < persons.length; i += CAPS.roleBatch) {
    const slice = persons.slice(i, i + CAPS.roleBatch);
    const entries = slice.map((c) => {
      const name = normalizeName(c.name);
      const hints = roleHints(c);
      const ev = (evidenceByName[name] || []).join("; ").slice(0, CAPS.evidenceChars);
      return `== ${name}\n${c.stats.tableRow}${hints.length ? "\nHINTS: " + hints.join("; ") : ""}${ev ? "\nEvidence: " + ev : ""}`;
    }).join("\n");
    const out = gen(rolesPrompt(entries), "synthesis");
    const known = new Set(slice.map((c) => normalizeName(c.name)));
    for (const line of out.split("\n")) {
      let t = line.trim();
      if (t.toUpperCase().startsWith("PERSON:")) t = t.slice(7).trim();
      const parts = t.split("|").map((p) => p.trim());
      if (parts.length >= 2 && known.has(parts[0])) {
        const raw = parts[1];
        const role = TAXONOMY_LIST.find((r) => raw.toLowerCase().includes(r.toLowerCase())) || "unclear";
        assignments[parts[0]] = { role, note: parts[2] || "" };
      }
    }
  }
  for (const c of persons) {
    const name = normalizeName(c.name);
    if (!assignments[name]) assignments[name] = { role: "unclear", note: "" };
  }
  const roleGraph = persons.map((c) => {
    const name = normalizeName(c.name);
    const a = assignments[name];
    return `${name} — ${a.role}${a.note ? ` (${a.note})` : ""}`;
  }).join("\n");
  log("roles:\n" + roleGraph);
  persons.slice(0, 4).forEach((c) => {
    const name = normalizeName(c.name);
    const a = assignments[name];
    if (a.role !== "unclear") ui.fact(`${name} — your ${a.role.toLowerCase()}`);
  });
  bump();

  // ---- Stage 4a: persona synthesis ----------------------------------------
  ui.status("Piecing together who you are…");
  const sectionBullets = {};
  const sectionGroups = [["ABOUT", "COMM", "WORK"],
                         ["INTERESTS", "HEALTH", "DAILY"],
                         ["DATES", "VALUES", "ASSIST"]];
  const personaOuts = genParallel(
    sectionGroups.map((tags) => personaPrompt(tags, roleGraph, observations)),
    "synthesis", 3);
  sectionGroups.forEach((tags, i) => {
    for (const [tag, bullet] of parseTagged(personaOuts[i] || "", new Set(tags))) {
      (sectionBullets[tag] = sectionBullets[tag] || []).push(bullet);
    }
    bump();
  });

  // ---- Stage 4t: timeline ---------------------------------------------------
  ui.status("Reconstructing your timeline…");
  const timeline = [];
  const sorted = eventMentions.sort((a, b) => a.date.localeCompare(b.date));
  let tBatch = [], tChars = 0;
  const flush = () => {
    if (!tBatch.length) return;
    const list = tBatch.map((m) => `${m.date} | ${m.text} | seen in: ${m.source}`).join("\n");
    const out = gen(timelinePrompt(list), "synthesis");
    for (let raw of out.split("\n")) {
      let e = raw.trim();
      if (e.startsWith("- ")) e = e.slice(2);
      e = e.replace(/\s*\(corroborated in 1 conversations?\)/i, "");
      if (e.length > 12 && (e.startsWith("20") || e.startsWith("19"))) timeline.push(e);
    }
    tBatch = []; tChars = 0;
  };
  for (const m of sorted) {
    if (tChars > CAPS.timelineBatchChars) flush();
    tBatch.push(m); tChars += m.text.length + 30;
  }
  flush();
  log(`timeline: ${timeline.length} entries from ${eventMentions.length} mentions`);
  if (timeline.length) ui.fact(timeline[timeline.length - 1]);
  bump();

  // ---- Stage 4b: cards — evidence-gated, qualitative only ------------------
  const cards = [];
  let skippedThin = 0;
  const cardTargets = relJobs.filter((c) => {
    const sig = evidenceByName[normalizeName(c.name)] || [];
    if (sig.length < CAPS.minSignalsForCard) { skippedThin++; return false; }
    return true;
  });
  completed += relJobs.length - cardTargets.length;   // keep progress math honest
  for (let i = 0; i < cardTargets.length; i += CAPS.parallel) {
    const batch = cardTargets.slice(i, i + CAPS.parallel);
    const outs = genParallel(batch.map((c) => {
      const name = normalizeName(c.name);
      const a = c.isGroup ? { role: "Group chat", note: "" } : assignments[name];
      return cardPrompt(c, a.role, a.note, evidenceByName[name] || []);
    }), null, CAPS.parallel);
    batch.forEach((c, j) => {
      const name = normalizeName(c.name);
      const a = c.isGroup ? { role: "Group chat", note: "" } : assignments[name];
      const bullets = (outs[j] || "").split("\n")
        .map((l) => l.trim().replace(/\s+/g, " "))
        .filter((l) => l.startsWith("- ") && !isTemplate(l) && !isStatBullet(l))
        .slice(0, 6);
      if (bullets.length) {
        const roleKnown = !c.isGroup && a.role !== "unclear";
        const heading = roleKnown ? `### ${name} · ${a.role}` : `### ${name}`;
        cards.push(heading + "\n" + bullets.join("\n"));
        ui.fact(`${name}: ${bullets[0].slice(2)}`);
      }
      bump();
    });
  }
  log(`cards: ${cards.length} written, ${skippedThin} skipped (thin evidence)`);

  // ---- Stage 5: polish + assemble -------------------------------------------
  let relations = cards.join("\n");
  if (relations.length && relations.length < 12000 && cards.length > 1) {
    ui.status("Double-checking claims…");
    const polished = gen(polishPrompt(relations, roleGraph), "synthesis");
    if (polished.includes("###") && polished.length > relations.length / 2) {
      relations = polished.trim();
    }
  }
  bump();

  const out = ["# Your Profile"];
  for (const [tag, heading] of SECTIONS) {
    const bullets = dedupe(sectionBullets[tag] || []);
    if (bullets.length) {
      out.push(`\n## ${heading}`);
      out.push(...bullets.map((b) => `- ${b}`));
    }
    if (tag === "COMM" && relations) {
      out.push("\n## Relationships");
      out.push(relations);
    }
    if (tag === "DATES" && timeline.length) {
      out.push("\n## Timeline");
      out.push(...timeline.map((t) => `- ${t}`));
    }
  }
  const profile = out.join("\n").trim();
  log(`harness v${HARNESS_VERSION} done: ${cards.length} cards, ${timeline.length} timeline entries, ${profile.length} chars; llm errors ${llmErrors}/${llmCalls}`);
  if (profile.length <= 40) {
    throw new Error(`pipeline produced an empty profile: ${persons.length} persons, ${observations.length} observations, ${cards.length} cards, llm errors ${llmErrors}/${llmCalls}${firstLlmError ? " — first error: " + firstLlmError : ""}`);
  }
  return profile;
}
