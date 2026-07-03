#!/usr/bin/env python3
"""Golden checks for a distilled profile (phase 6 of the improvement plan).

Usage: golden.py profile.md harness.log
Exits non-zero if any hard check fails. Ground truth is Nik's corpus:
Hanan = partner, businesses like Delta must not get relationship cards.
"""
import re
import sys

profile_path, log_path = sys.argv[1], sys.argv[2]
profile = open(profile_path, encoding="utf-8").read()
try:
    log = open(log_path, encoding="utf-8").read()
except OSError:
    log = ""
# Only score the current run: the log rotates, but reports/copies can
# concatenate the previous run after a marker.
log = log.split("=== PREVIOUS RUN ===")[0]

results = []  # (name, passed, detail)


def check(name, passed, detail=""):
    results.append((name, bool(passed), detail))


def section(title):
    m = re.search(rf"^## {title}\n(.*?)(?=^## |\Z)", profile, re.M | re.S)
    return m.group(1) if m else ""


rel = section("Relationships")
timeline = section("Timeline")
cards = re.findall(r"^### (.+?)$(.*?)(?=^### |\Z)", rel, re.M | re.S)

# --- Relationships -----------------------------------------------------------
check("cards_exist", len(cards) >= 6, f"{len(cards)} cards")

hanan = [(h, b) for h, b in cards if re.search(r"hanan", h, re.I)]
check("hanan_card", bool(hanan), "no card for Hanan")
if hanan:
    check("hanan_role", re.search(r"partner|spouse|wife|fianc", hanan[0][0], re.I),
          f"heading: {hanan[0][0]!r}")

BUSINESS = r"\b(delta|jetblue|united|amex|chase|verizon|cvs|walgreens|amazon|doordash|equinox)\b"
biz = [h for h, _ in cards if re.search(BUSINESS, h, re.I)]
check("no_business_cards", not biz, f"business cards: {biz}")

stat = re.findall(
    r"^- .*?(?:\b\d[\d,]* (?:message|text)|%|last contact|median|\bunclear\b).*$",
    rel, re.M | re.I)
check("no_stat_bullets", not stat, f"{len(stat)} stat bullets, e.g. {stat[:2]}")

# --- Timeline ----------------------------------------------------------------
entries = re.findall(r"^- ", timeline, re.M)
check("timeline_present", len(entries) >= 5, f"{len(entries)} entries")
check("timeline_capped", len(entries) <= 120, f"{len(entries)} entries")

# --- Whole-profile hygiene ---------------------------------------------------
placeholders = re.findall(r"\[[A-Za-z][A-Za-z /']{2,40}\]", profile)
check("no_placeholders", not placeholders, f"e.g. {placeholders[:3]}")
check("no_filler", not re.search(r"no observations available", profile, re.I))
check("owner_identity", "Nik" in profile[:600],
      f"head: {profile[:120]!r}")
check("size_sane", 2_000 <= len(profile) <= 40_000, f"{len(profile)} chars")

# --- Log-side vitals ---------------------------------------------------------
signals = sum(int(n) for n in re.findall(r"\+(\d+) signals", log))
check("log_signals", signals >= 100, f"{signals} total signals")
m = re.search(r"cards: (\d+) written, (\d+) skipped", log)
check("log_cards_written", m and int(m.group(1)) >= 6,
      m.group(0) if m else "no cards line")
v = re.search(r"harness v(\d+) starting", log)
check("log_harness_version", v, v.group(0) if v else "no version line")

# --- Soft signals (reported, never fail) -------------------------------------
for warmth in ("triathlon|ironman|swim|bike|run", "google|product manager"):
    if not re.search(warmth, profile, re.I):
        print(f"  note: profile never mentions /{warmth}/")

failed = [r for r in results if not r[1]]
for name, passed, detail in results:
    print(f"  {'PASS' if passed else 'FAIL'}  {name:22s} {detail}")
print(f"golden: {len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
