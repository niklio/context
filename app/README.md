# Context Layer — v1 menu-bar app

Turns your iMessage history into a portable profile you review, edit, and hand
to any assistant. Local-first: raw messages never leave the Mac — extraction
AND distillation run on-device (Gemma via Ollama), so only the distilled,
user-approved profile ever exists as an artifact.

## Install (on the machine with your Messages history)

1. Copy `build/ContextLayer-0.1.0.zip` over and unzip into `/Applications`.
2. First launch: macOS blocks unsigned apps — System Settings → Privacy &
   Security → scroll down → **Open Anyway** (not notarized yet).
2b. Menu-bar icon appears → follow the Full Disk Access walkthrough
   (System Settings → Privacy & Security → Full Disk Access → enable
   Context Layer). The app detects the grant within ~2s.
3. Click **Build my profile**. Local stats stream while it reads; distillation
   runs fully on-device with Gemma. The Ollama runtime is bundled inside the
   app (arm64-thinned `ollama` + `llama-server` in Contents/MacOS — nothing to
   install); the `gemma3:4b` weights download once (~3.3 GB). Override the
   model with `CL_MODEL=...`.
4. Review/edit the profile, then use the Claude / ChatGPT / Gemini buttons:
   each copies the inject block to the clipboard and opens the assistant —
   paste and send.

Profile lives at `~/Library/Application Support/ContextLayer/profile.md`.
Delete from the review window, or just delete the file.

## Build

```
./build.sh          # needs Command Line Tools only (no Xcode)
```

Produces `build/ContextLayer.app` and the zip.

## Headless mode (testing / scripting)

```
.build/release/ContextLayer --headless [chat.db] [--out profile.md] [--no-distill]
```

Points at any chat.db copy (e.g. one scp'd from another Mac). `--no-distill`
runs extraction + stats only.

## Architecture notes

- `ChatDB.swift` — snapshots db+wal+shm to a temp dir, checkpoints the WAL on
  the copy (recent messages live in the WAL), reads via SQLite3 C API. Never
  touches the live store.
- `TypedStream.swift` — decodes `attributedBody` (modern message text is
  there, not in the `text` column). Handles 1-byte / 0x81+u16 / 0x82+u32
  length encodings.
- Timestamps: Apple-epoch nanoseconds (`unix = ns/1e9 + 978307200`), with the
  pre-High-Sierra seconds format auto-detected.
- `Distiller.swift` — fully local map-reduce over top-40 chats (last 400 msgs
  each, ~20k-char chunks, ≤24 chunks) against Ollama's HTTP API
  (`gemma3:4b`, `num_ctx` 16384). Auto-starts `ollama serve`, auto-pulls the
  model with progress on first run, hierarchically merges observations in
  batches (small models can't reduce hundreds of bullets in one shot), then
  one reduce call produces the profile markdown. Prompts scope observations
  to the user only — no dossiers on contacts.
- `codesign -s -` with a stable identifier so the FDA grant survives rebuilds
  on the same machine. Developer ID + notarization is a later step.

## Bundling gotchas (learned the hard way)

- Executable code must live in `Contents/MacOS`; dangling symlinks anywhere
  in the bundle break the codesign seal and Gatekeeper reports the app as
  "damaged or incomplete".
- Ollama's darwin binaries are statically linked: the dylibs and MLX runtimes
  in the release tarball are unnecessary for the ggml Metal path.
- Releases are served from Cloudflare R2 (`context-releases` bucket) via the
  site Worker — Workers static assets cap at 25 MB/file.
