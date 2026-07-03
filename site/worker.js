const MAX_PROFILE_BYTES = 100_000;
const UNCLAIMED_TTL_S = 30 * 24 * 3600; // unclaimed profiles self-delete in 30d

function randomHex(bytes) {
  return [...crypto.getRandomValues(new Uint8Array(bytes))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // The harness and appcast must NEVER be cached — hot-reload depends on
    // every fetch seeing the latest deploy (edge-cached assets served v10 to
    // a user an hour after v11 shipped).
    if (url.pathname === "/harness.js" || url.pathname === "/appcast.xml") {
      const resp = await env.ASSETS.fetch(request);
      const fresh = new Response(resp.body, resp);
      fresh.headers.set("cache-control", "no-store, must-revalidate");
      return fresh;
    }

    // Releases live in R2 (too big for static assets).
    const rel = url.pathname.match(/^\/((?:ContextLayer|Context)-[\w.]+\.(zip|dmg))$/);
    if (rel) {
      const obj = await env.RELEASES.get(rel[1]);
      if (!obj) return new Response("not found", { status: 404 });
      return new Response(obj.body, {
        headers: {
          "content-type": rel[2] === "dmg"
            ? "application/x-apple-diskimage" : "application/zip",
          "content-length": obj.size,
          "content-disposition": `attachment; filename="${rel[1]}"`,
          "cache-control": "public, max-age=3600",
        },
      });
    }

    // First upload from the Mac app. Returns a write-token so the app can
    // keep re-publishing the same profile (auto-update) before any account
    // exists; account creation later claims the id without touching the token.
    if (url.pathname === "/api/profiles" && request.method === "POST") {
      let body;
      try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
      const profile = typeof body.profile === "string" ? body.profile.trim() : "";
      if (!profile) return json({ error: "empty profile" }, 400);
      if (profile.length > MAX_PROFILE_BYTES) return json({ error: "profile too large" }, 413);
      const id = randomHex(20);          // 160-bit unguessable view link
      const token = randomHex(32);       // 256-bit write credential
      await env.PROFILES.put(id, JSON.stringify({
        profile,
        tokenHash: await sha256(token),
        created: new Date().toISOString(),
        updated: new Date().toISOString(),
      }), { expirationTtl: UNCLAIMED_TTL_S });
      return json({ id, url: `${url.origin}/p/${id}`, token });
    }

    // Re-publish (auto-update / approved update) — requires the write-token.
    const put = url.pathname.match(/^\/api\/profiles\/([a-f0-9]{30,50})$/);
    if (put && request.method === "PUT") {
      const stored = await env.PROFILES.get(put[1]);
      if (!stored) return json({ error: "not found" }, 404);
      const record = JSON.parse(stored);
      const token = (request.headers.get("authorization") || "").replace(/^Bearer /, "");
      if (!token || (await sha256(token)) !== record.tokenHash) {
        return json({ error: "unauthorized" }, 401);
      }
      let body;
      try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
      const profile = typeof body.profile === "string" ? body.profile.trim() : "";
      if (!profile) return json({ error: "empty profile" }, 400);
      if (profile.length > MAX_PROFILE_BYTES) return json({ error: "profile too large" }, 413);
      record.profile = profile;
      record.updated = new Date().toISOString();
      await env.PROFILES.put(put[1], JSON.stringify(record),
        { expirationTtl: UNCLAIMED_TTL_S });
      return json({ ok: true });
    }

    // Full local-model trajectory (gzipped JSONL of every prompt+response)
    // accompanying a report. User-consented — prompts contain message
    // excerpts. Too big for KV, so it lands in R2 next to the releases;
    // only ids of existing reports are accepted.
    const traj = url.pathname.match(/^\/api\/reports\/([\w-]{10,80})\/trajectory$/);
    if (traj && request.method === "POST") {
      if (!(await env.PROFILES.get("report:" + traj[1]))) {
        return json({ error: "unknown report" }, 404);
      }
      const body = await request.arrayBuffer();
      if (body.byteLength > 50_000_000) return json({ error: "too large" }, 413);
      await env.RELEASES.put(`debug/${traj[1]}.jsonl.gz`, body);
      return json({ ok: true });
    }

    // Failure reports from the app: error + harness.log + environment.
    // 30-day TTL, pulled via wrangler.
    if (url.pathname === "/api/reports" && request.method === "POST") {
      let body;
      try { body = await request.json(); } catch { return json({ error: "bad json" }, 400); }
      const report = JSON.stringify(body);
      if (report.length > 200_000) return json({ error: "report too large" }, 413);
      const id = new Date().toISOString().replace(/[:.]/g, "-") + "-" + randomHex(3);
      await env.PROFILES.put("report:" + id, report,
        { expirationTtl: 30 * 24 * 3600 });
      return json({ ok: true, id });
    }

    // Profile deletion (the id itself is the bearer secret).
    const del = url.pathname.match(/^\/api\/profiles\/([a-f0-9]{30,50})$/);
    if (del && request.method === "DELETE") {
      await env.PROFILES.delete(del[1]);
      return json({ ok: true });
    }

    // Profile web page.
    const page = url.pathname.match(/^\/p\/([a-f0-9]{30,50})$/);
    if (page && request.method === "GET") {
      const stored = await env.PROFILES.get(page[1]);
      if (!stored) return new Response(notFoundPage(), {
        status: 404, headers: { "content-type": "text/html;charset=utf-8" } });
      const { profile, created } = JSON.parse(stored);
      return new Response(profilePage(page[1], profile, created), {
        headers: {
          "content-type": "text/html;charset=utf-8",
          "cache-control": "no-store",
          "x-robots-tag": "noindex",
        },
      });
    }

    return env.ASSETS.fetch(request);
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { "content-type": "application/json" } });
}

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Minimal markdown: #/## headings, "- " bullets, paragraphs.
function mdToHtml(md) {
  const lines = md.split("\n");
  let html = "", list = false, para = [];
  const flush = () => {
    if (para.length) { html += `<p>${esc(para.join(" "))}</p>`; para = []; }
  };
  const closeList = () => { if (list) { html += "</ul>"; list = false; } };
  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim()) { flush(); closeList(); continue; }
    if (line.startsWith("### ")) { flush(); closeList(); html += `<h3>${esc(line.slice(4))}</h3>`; }
    else if (line.startsWith("## ")) { flush(); closeList(); html += `<h2>${esc(line.slice(3))}</h2>`; }
    else if (line.startsWith("# ")) { flush(); closeList(); html += `<h1>${esc(line.slice(2))}</h1>`; }
    else if (line.startsWith("- ")) {
      flush(); if (!list) { html += "<ul>"; list = true; }
      html += `<li>${esc(line.slice(2))}</li>`;
    } else para.push(line.trim());
  }
  flush(); closeList();
  return html;
}

const STYLE = `
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         margin: 0; color: #2b2620; background: #faf6ec; }
  .wrap { max-width: 640px; margin: 0 auto; padding: 48px 24px 80px; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
  header img { width: 40px; height: 40px; border-radius: 10px; }
  header b { font-size: 1.15em; }
  .muted { color: #8d8574; }
  .card { background: #fffdf6; border: 1.5px solid #e7dcc2; border-radius: 16px;
          padding: 8px 24px 20px; margin: 20px 0; }
  .card h1 { font-size: 1.3em; } .card h2 { font-size: 1.02em; margin: 18px 0 6px; }
  .card h3 { font-size: .95em; margin: 14px 0 3px; }
  .card p, .card li { font-size: .95em; }
  .conn { display: flex; align-items: center; justify-content: space-between;
          background: #fffdf6; border: 1.5px solid #e7dcc2; border-radius: 14px;
          padding: 14px 18px; margin: 10px 0; }
  .conn b { font-size: .98em; }
  .conn span { display: block; font-size: .78em; color: #8d8574; }
  button, .btn { font: 600 .9em -apple-system, sans-serif; border: 0; cursor: pointer;
          background: #0a7bf5; color: #fff; padding: 9px 16px; border-radius: 9px;
          text-decoration: none; }
  button.ghost { background: #f0e9d8; color: #2b2620; }
  button.danger { background: transparent; color: #b3543f; font-weight: 500; }
  h3 { margin: 30px 0 4px; }
  footer { margin-top: 40px; font-size: .78em; color: #8d8574; text-align: center; }
  footer a { color: #0a7bf5; text-decoration: none; }
`;

function profilePage(id, profile, created) {
  const injectBlock = (assistant) =>
    `Please remember the following about me and use it as standing context in our conversations. It was distilled from my own message history by Context, reviewed and approved by me.\n\n${profile}`;
  const conns = [
    ["Claude", "https://claude.ai/new"],
    ["ChatGPT", "https://chatgpt.com/"],
    ["Gemini", "https://gemini.google.com/app"],
  ];
  return `<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>your context</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml"><style>${STYLE}</style></head>
<body><div class="wrap">
  <header><img src="/icon.svg" alt=""><div><b>Context</b>
    <span class="muted" style="display:block;font-size:.78em">your profile · created ${esc(created.slice(0, 10))}</span>
  </div></header>

  <h3>Connections</h3>
  <p class="muted" style="font-size:.85em;margin:2px 0 12px">
    Each button copies your profile as a ready-to-paste block and opens the assistant.</p>
  ${conns.map(([name, link]) => `
    <div class="conn"><div><b>${name}</b><span>paste once — it remembers</span></div>
      <button onclick="inject('${name}','${link}')">Connect</button></div>`).join("")}

  <h3>Your profile</h3>
  <div class="card" id="profile">${mdToHtml(profile)}</div>

  <div style="text-align:center">
    <button class="ghost" onclick="copyProfile()">Copy profile</button>
    <button class="danger" onclick="del()">Delete from server</button>
  </div>

  <footer>only you have this link · <a href="https://context.nikliolios.com">context</a>
    — raw messages never left your mac; this page holds only the profile you generated</footer>
</div>
<script>
  const BLOCK = ${JSON.stringify(injectBlock(""))};
  function inject(name, link) {
    navigator.clipboard.writeText(BLOCK).then(() => window.open(link, "_blank"));
  }
  function copyProfile() { navigator.clipboard.writeText(BLOCK); }
  async function del() {
    if (!confirm("Delete your profile from the server? Your local copy in the app is unaffected.")) return;
    await fetch("/api/profiles/${id}", { method: "DELETE" });
    document.body.innerHTML = "<div class='wrap'><p>Deleted. This link is now dead.</p></div>";
  }
</script></body></html>`;
}

function notFoundPage() {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${STYLE}</style></head>
<body><div class="wrap"><header><img src="/icon.svg" style="width:40px;border-radius:10px"><b>Context</b></header>
<p>This profile doesn't exist — it may have been deleted.</p></div></body></html>`;
}
