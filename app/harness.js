// Context distillation harness — hot-reloaded from context.nikliolios.com/harness.js
// Runs sandboxed in the app's JavaScriptCore runtime: the only capabilities are
// host.* (local corpus), llm.* (local model), ui.* (progress), log().
//
// Architecture: evidence → merge → synthesize → write.
// Local passes observe (no conclusions, no superlatives); the global synthesis
// stages — the only stages that see everyone — judge.
const HARNESS_VERSION = 6;

const CAPS = {
  persons: 25,
  groups: 5,
  businesses: 15,
  transcriptChars: 12000,
  evidenceChars: 700,
  obsPerTag: 40,
  timelineBatchChars: 9000,
  parallel: 4, // matches the server's OLLAMA_NUM_PARALLEL (older binaries clamp to 2)
};

const TAXONOMY =
  "Spouse/Wife/Husband, Partner, Girlfriend/Boyfriend, Mother, Father, " +
  "Sibling, Child, Grandparent, Extended family, In-law, Close friend, " +
  "Friend, Roommate, Manager, Direct report, Colleague, Client, " +
  "Service provider, Acquaintance, unclear";

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

// ---------------------------------------------------------------- helpers

let llmErrors = 0, llmCalls = 0, firstLlmError = null;
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

function isFiller(s) {
  const l = s.toLowerCase();
  return (
    l.includes("no observation") || l.includes("n/a") ||
    l.includes("insufficient") || l.includes("not enough evidence") ||
    l.includes("nothing to conclude")
  );
}

function isTemplate(s) {
  return s.includes("[") && s.includes("]");
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

function parseEvidence(output, source) {
  const signals = [], obs = [], events = [];
  for (let raw of output.split("\n")) {
    let line = raw.trim();
    if (line.startsWith("- ")) line = line.slice(2);
    const upper = line.toUpperCase();
    if (upper.startsWith("SIGNAL:")) {
      const body = line.slice(7).trim();
      if (body.length > 8) signals.push(body);
    } else if (upper.startsWith("HYPOTHESIS:")) {
      const body = line.slice(11).trim();
      if (body.length > 8) signals.push("hypothesis: " + body);
    } else if (upper.startsWith("EVENT:")) {
      const parts = line.slice(6).split("|").map((p) => p.trim());
      if (parts.length >= 2 && parts[0].length >= 4 &&
          (parts[0].startsWith("20") || parts[0].startsWith("19")) &&
          parts[1].length > 6) {
        events.push({
          date: parts[0], text: parts[1], source,
          explicit: parts.length > 2 && parts[2].toLowerCase().includes("explicit"),
        });
      }
    } else if (upper.startsWith("OBS:")) {
      const parts = line.slice(4).split("|").map((p) => p.trim());
      if (parts.length === 3) {
        const tag = parts[0].toUpperCase();
        if (VALID_TAGS.has(tag) && parts[2].length > 8 &&
            !isFiller(parts[2]) && !isTemplate(parts[2])) {
          obs.push({
            tag, text: parts[2], source,
            explicit: parts[1].toLowerCase().includes("explicit"),
          });
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
    const tag = line.slice(0, colon).trim().toUpperCase();
    const body = line.slice(colon + 1).trim();
    if (validTags.has(tag) && body.length > 8 && !isFiller(body) && !isTemplate(body)) {
      results.push([tag, body]);
    }
  }
  return results;
}

function cleanCard(output, name, role) {
  const bullets = output.split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("- ") && !isTemplate(l))
    .map((l) => l.replace(/\s+/g, " "))
    .slice(0, 10);
  if (!bullets.length) return "";
  const heading = role && role.toLowerCase() !== "unclear" && role !== "Group chat"
    ? `### ${name} · ${role}` : `### ${name}`;
  return heading + "\n" + bullets.join("\n");
}

// ---------------------------------------------------------------- prompts

const NO_CONCLUSIONS =
  "You are gathering EVIDENCE from one conversation in my message history. This " +
  "runs locally at my request. You see ONLY this conversation, so you must not " +
  "draw conclusions that require seeing my other relationships: NO role verdicts, " +
  'NO superlatives ("closest", "best friend", "favorite"), NO "always/never" ' +
  "claims. Evidence only — a later stage that sees everything will judge.";

const PERSONA_TAGS =
  "OBS: <TAG> | <explicit or inferred> | <complete sentence about Me>\n" +
  "Tags: ABOUT (identity: name, job, city, life stage), COMM (how I write in THIS " +
  "conversation), WORK, INTERESTS, HEALTH, DAILY, DATES (upcoming dates/events), " +
  "VALUES, ASSIST (how an assistant could help me based on what I ask for here). " +
  "Specifics beat generalities; only what this transcript supports.\n\n" +
  "Also extract every real-world EVENT from my life this conversation evidences — " +
  "small (met someone for breakfast, a dinner, a ride) or big (wedding, move, new " +
  "job, race, birth). Date each one using the [YYYY-MM-DD] message timestamps " +
  '("yesterday"/"next Saturday" resolve relative to the message\'s date):\n' +
  "EVENT: <YYYY-MM-DD or YYYY-MM> | <what happened> | <explicit or inferred>";

function evidencePrompt(chat, transcript) {
  if (chat.kind === "business" || chat.kind === "automated") {
    return `${NO_CONCLUSIONS}

This is a conversation with a business/automated sender ("${chat.name}"). Extract only persona observations about Me (what it reveals about my travel, purchases, appointments, habits). Output ONLY OBS and EVENT lines:
${PERSONA_TAGS}

TRANSCRIPT:
${transcript}`;
  }
  return `${NO_CONCLUSIONS}

Conversation with ${chat.name}${chat.isGroup ? " (group chat)" : ""}. Measured: ${chat.stats.tableRow}.

Output THREE kinds of lines, nothing else:
SIGNAL: <role-relevant evidence with its supporting detail — how we address each other ("mom", "babe", first names), events mentioned (anniversary, performance review, family dinners), shared logistics (same home, kids, projects), emotional register>
HYPOTHESIS: <a possible relationship role> — <the evidence for it> (several allowed; uncertainty is fine)
${PERSONA_TAGS}

TRANSCRIPT:
${transcript}`;
}

function rolesPrompt(entries) {
  return `You can now see ALL of my personal relationships at once — the only vantage point from which comparative judgments are legitimate. For each person, using their measured stats and gathered evidence (and comparing across people), assign the most specific relationship role the evidence supports.

Taxonomy: ${TAXONOMY}

Rules:
- Prefer "unclear" over guessing when evidence is thin.
- Evidence may need combining: pet names + shared home + anniversary → Spouse or Partner; choose Spouse only with marriage evidence.
- Comparative calls ARE allowed here and only here: you may name a "closest friend" if the whole picture (cadence, history, what we confide, the stats) clearly supports one; if it's close between several, say "one of my closest friends" in the note instead.
- At most ONE person may carry a "closest friend" note.

Output exactly one line per person:
PERSON: <name> | <role> | <optional short note, e.g. comparative context>

${entries}`;
}

const SECTION_GUIDANCE = {
  ABOUT: "Triangulate identity: name from how people address me, job/city corroborated across conversations. Resolve contradictions by recency and say so ('moved from X to Y').",
  COMM: "Compare my style ACROSS audiences using the role graph — describe the register shifts (how I write to my partner vs colleagues vs friends), not one thread's tone.",
  WORK: "Separate corroborated facts (employer, role) from ambitions and side projects.",
  INTERESTS: "Tier them: core interests (many conversations, long span, recent) vs current phase vs historical. Weigh breadth of audiences, not enthusiasm in one thread.",
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
      const lines = capped.map(
        (o) => `- [${o.source}, ${o.explicit ? "explicit" : "inferred"}] ${o.text}`);
      return `${t} observations:\n` + lines.join("\n");
    })
    .join("\n\n");

  return `You are synthesizing sections of my profile from observations gathered across ALL my conversations — each carries its source. You also know who everyone is to me:

${roleGraph}

Section guidance (instructions for you — NEVER copy these into the output):
${tags.map((t) => `• ${t} — ${SECTION_GUIDANCE[t] || ""}`).join("\n")}

Cross-reference the observations: facts seen across several conversations and recent time periods are load-bearing; one-off inferred items are background or droppable. Write final profile bullets, each a complete sentence about me, in the form \`TAG: bullet\`. A tag with no observations gets NO output lines. If the observations are too thin to conclude anything, output nothing for that tag — never pad, never restate the guidance. Output ONLY conclusion lines.

${body}`;
}

function timelinePrompt(mentionList) {
  return `Below are mentions of real-world events from my life, gathered from different conversations, sorted by date. Merge them into a clean chronological timeline:
- Mentions of the SAME real-world event (same date range, same happening, possibly described differently to different people) become ONE entry. Count the distinct conversations it appeared in; if 2 or more, append " (corroborated in N conversations)" — more corroboration means more confidence it happened.
- Keep small events (a breakfast, a ride, a dinner) AND big ones (weddings, moves, job changes). Drop non-events and pure plans that never resolved.
- Output one line per event, exactly: \`<YYYY-MM-DD or YYYY-MM> — <event>\` with the optional corroboration suffix. Chronological order. Nothing else.

${mentionList}`;
}

function cardPrompt(chat, role, note, evidence) {
  return `Write my relationship card for ${chat.name}. The role was determined by a stage that compared all my relationships: ${role}${note ? " — " + note : ""}.
Measured: ${chat.stats.tableRow}
Evidence gathered: ${evidence.join("; ").slice(0, 1400)}

Output: first line exactly \`### ${chat.name}\`, then 1 to 10 bullets (\`- \`). The first bullet states who they are to me using the given role naturally. Cover what we talk about, how we communicate, shared history and plans, practical facts, how we support each other. Only evidence-supported claims; do NOT add comparative claims beyond the note; no speculation. If you lack evidence for a bullet, omit it — NEVER write placeholders or bracketed templates. Fewer, real bullets beat padded ones. Output ONLY the heading and bullets.`;
}

function polishPrompt(section, roleGraph) {
  return `Below is the Relationships section of my profile, plus the authoritative role assignments. Fix ONLY these problems, changing nothing else:
- superlatives ("closest", "best", "favorite") that are NOT in the role assignments — soften them ("a close friend")
- role contradictions with the assignments
Return the full corrected section verbatim otherwise, starting with the first ###.

ROLE ASSIGNMENTS:
${roleGraph}

SECTION:
${section}`;
}

// ---------------------------------------------------------------- pipeline

function statFact(c) {
  const s = c.stats;
  const opts = [];
  if (s.spanDays > 365) {
    opts.push(`${c.messageCount.toLocaleString()} messages with ${c.name} across ${(s.spanDays / 365).toFixed(1)} years`);
  } else if (c.messageCount > 50) {
    opts.push(`${c.messageCount.toLocaleString()} messages with ${c.name}`);
  }
  if (s.myInitiationShare >= 0.65) {
    opts.push(`You start ${Math.round(s.myInitiationShare * 100)}% of your conversations with ${c.name}`);
  } else if (s.myInitiationShare <= 0.35 && c.messageCount > 30) {
    opts.push(`${c.name} usually texts you first`);
  }
  if (s.perWeek >= 20) {
    opts.push(`You and ${c.name} trade ${Math.round(s.perWeek)} messages a week`);
  }
  return opts.length ? opts[c.id % opts.length] : null;
}

function distill() {
  log(`harness v${HARNESS_VERSION} starting`);
  const all = host.chats();
  log(`runtime handed ${all.length} conversations`);
  if (!all.length) {
    throw new Error("the runtime handed the harness 0 conversations — corpus serialization problem in the app");
  }

  // Stage 0 — classification (heuristic kinds precomputed by the host).
  const groups = all.filter((c) => c.isGroup)
    .sort((a, b) => b.messageCount - a.messageCount).slice(0, CAPS.groups);
  let persons = all.filter((c) => !c.isGroup && c.kind === "person");
  let businesses = all.filter((c) => !c.isGroup && (c.kind === "business" || c.kind === "automated"));
  const ambiguous = all.filter((c) => !c.isGroup && c.kind === "ambiguous");
  if (ambiguous.length) {
    const listing = ambiguous.map((c, i) =>
      `${i + 1}. ${c.name}: ${(c.sampleIncoming || []).join(" ⏐ ")}`).join("\n");
    const out = gen(
      `For each numbered sender below, decide if it is a real PERSON I know, or a BUSINESS/automated sender (airline, bank, store, appointment reminders, verification codes, delivery notices). Output one line per number, exactly:\n<number>. PERSON  or  <number>. BUSINESS\n\n${listing}`);
    const verdicts = {};
    for (const line of out.split("\n")) {
      const m = line.match(/^\s*(\d+)\.\s*(PERSON|BUSINESS)/i);
      if (m) verdicts[parseInt(m[1], 10)] = m[2].toUpperCase();
    }
    ambiguous.forEach((c, i) => {
      (verdicts[i + 1] === "BUSINESS" ? businesses : persons).push(c);
    });
  }
  persons = persons.sort((a, b) => b.messageCount - a.messageCount).slice(0, CAPS.persons);
  businesses = businesses.sort((a, b) => b.messageCount - a.messageCount).slice(0, CAPS.businesses);

  log(`classified: ${persons.length} persons, ${groups.length} groups, ${businesses.length} businesses (of ${all.length})`);
  // Facts flow from second zero: corpus headlines, then per-conversation
  // stat nuggets as we reach each one, then real insights displace them.
  for (const headline of host.corpusHeadlines().slice(0, 3)) ui.fact(headline);

  const jobs = [...persons, ...groups, ...businesses];
  if (!jobs.length) {
    throw new Error(`classification produced 0 usable conversations from ${all.length} — check harness.log`);
  }
  const totalUnits = jobs.length + persons.length + groups.length + 6;
  let completed = 0;
  const bump = () => ui.progress(++completed, totalUnits);

  // Stage 1 — evidence passes, in host-parallel pairs.
  const evidenceByName = {};
  const observations = [];
  const eventMentions = [];
  for (let i = 0; i < jobs.length; i += CAPS.parallel) {
    const batch = jobs.slice(i, i + CAPS.parallel);
    // A stat nugget for someone in this batch, shown while the model reads.
    for (const c of batch) {
      const f = statFact(c);
      if (f) { ui.fact(f); break; }
    }
    const prompts = batch.map((c) => evidencePrompt(
      c, host.transcript(c.id, { maxChars: CAPS.transcriptChars })));
    const outputs = genParallel(prompts, null, CAPS.parallel);
    batch.forEach((c, j) => {
      const { signals, obs, events } = parseEvidence(outputs[j] || "", c.name);
      evidenceByName[c.name] = (evidenceByName[c.name] || []).concat(signals);
      observations.push(...obs);
      eventMentions.push(...events);
      if (obs.length) ui.fact(obs[0].text);
      bump();
    });
  }

  log(`evidence: ${observations.length} observations, ${eventMentions.length} event mentions, signals for ${Object.keys(evidenceByName).length} people; llm errors ${llmErrors}/${llmCalls}`);
  assertLlmHealthy("evidence");

  // Stage 3 — relationship synthesis: the one pass that sees everyone.
  ui.status("Figuring out who's who…");
  const entries = persons.map((c) => {
    const ev = (evidenceByName[c.name] || []).join("; ").slice(0, CAPS.evidenceChars);
    return `== ${c.name}\n${c.stats.tableRow}${ev ? "\nEvidence: " + ev : ""}`;
  }).join("\n");
  const rolesOut = persons.length
    ? gen(rolesPrompt(entries), "synthesis") : "";
  const assignments = {};
  const knownNames = new Set(persons.map((c) => c.name));
  for (const line of rolesOut.split("\n")) {
    let t = line.trim();
    if (t.toUpperCase().startsWith("PERSON:")) t = t.slice(7).trim();
    const parts = t.split("|").map((p) => p.trim());
    // Accept prefix-less lines too — small models drop the PERSON: marker —
    // but only when the first segment is an actual known person.
    if (parts.length >= 2 && knownNames.has(parts[0])) {
      assignments[parts[0]] = { role: parts[1], note: parts[2] || "" };
    }
  }
  for (const c of persons) {
    if (!assignments[c.name]) assignments[c.name] = { role: "unclear", note: "" };
  }
  const roleGraph = persons.map((c) => {
    const a = assignments[c.name];
    return `${c.name} — ${a.role}${a.note ? ` (${a.note})` : ""}`;
  }).join("\n");
  Object.entries(assignments).slice(0, 3).forEach(([n, a]) => {
    if (a.role.toLowerCase() !== "unclear") ui.fact(`${n} — ${a.role.toLowerCase()}`);
  });
  bump();

  // Stage 4a — persona synthesis (consumes the role graph).
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

  // Stage 4t — timeline: merge event mentions, count corroborations.
  ui.status("Reconstructing your timeline…");
  const timeline = [];
  const sorted = eventMentions.sort((a, b) => a.date.localeCompare(b.date));
  let batch = [], chars = 0;
  const flushBatch = () => {
    if (!batch.length) return;
    const list = batch.map((m) => `${m.date} | ${m.text} | seen in: ${m.source}`).join("\n");
    const out = gen(timelinePrompt(list), "synthesis");
    for (let raw of out.split("\n")) {
      let e = raw.trim();
      if (e.startsWith("- ")) e = e.slice(2);
      if (e.length > 12 && (e.startsWith("20") || e.startsWith("19"))) timeline.push(e);
    }
    batch = []; chars = 0;
  };
  for (const m of sorted) {
    if (chars > CAPS.timelineBatchChars) flushBatch();
    batch.push(m); chars += m.text.length + 30;
  }
  flushBatch();
  if (timeline.length) ui.fact(timeline[timeline.length - 1]);
  bump();

  // Stage 4b — relationship cards.
  const cards = [];
  const cardTargets = [...persons, ...groups];
  for (let i = 0; i < cardTargets.length; i += CAPS.parallel) {
    const batch = cardTargets.slice(i, i + CAPS.parallel);
    const outs = genParallel(batch.map((c) => {
      const a = c.isGroup ? { role: "Group chat", note: "" } : assignments[c.name];
      return cardPrompt(c, a.role, a.note, evidenceByName[c.name] || []);
    }), null, CAPS.parallel);
    batch.forEach((c, j) => {
      const a = c.isGroup ? { role: "Group chat", note: "" } : assignments[c.name];
      const card = cleanCard(outs[j] || "", c.name, c.isGroup ? null : a.role);
      if (card) {
        cards.push(card);
        const fb = card.split("\n").find((l) => l.startsWith("- "));
        if (fb) ui.fact(`${c.name}: ${fb.slice(2)}`);
      }
      bump();
    });
  }

  // Stage 5 — polish + assemble.
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
