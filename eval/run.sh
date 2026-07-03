#!/bin/zsh
# Full eval run: headless distill over the real corpus → golden checks.
# GPU work is serialized with nlearn via gpu-lock (see ~/.claude-rc/GPU_POLICY.md).
set -euo pipefail
cd "$(dirname "$0")/.."

TS=$(date +%Y%m%d-%H%M%S)
OUT="eval/out/$TS"
mkdir -p "$OUT"

export CL_ADDRESSBOOK="$PWD/eval/corpus/AddressBook"
export CL_OWNER="Nik Liolios"
export CL_HARNESS="$PWD/app/harness.js"   # eval always runs the LOCAL harness

echo "eval run $TS → $OUT (harness: $(grep -o 'HARNESS_VERSION = [0-9]*' app/harness.js))"
GPU_LOCK_LABEL=context:eval ~/.local/bin/gpu-lock \
  app/.build/release/ContextLayer --headless "$PWD/eval/corpus/chat.db" \
  --out "$OUT/profile.md" 2>&1 | tee "$OUT/run.log"

SUPPORT="$HOME/Library/Application Support/ContextLayer"
cp "$SUPPORT/harness.log" "$OUT/harness.log" 2>/dev/null || true
cp "$SUPPORT/trajectory.jsonl" "$OUT/trajectory.jsonl" 2>/dev/null || true

# Be a good tenant: free the model's VRAM instead of waiting out keep-alive.
lsof -ti tcp:11435 | xargs kill 2>/dev/null || true

python3 eval/golden.py "$OUT/profile.md" "$OUT/harness.log" | tee "$OUT/golden.txt"
