#!/usr/bin/env python3
"""Graded profile scorer over the ground-truth answer key.

Usage: score.py profile.md [key.json] [--json out.json] [--misses]

Key schema (eval/groundtruth/key.json — gitignored, contains personal facts):
{
  "items": [{
    "id": "identity.job", "tier": 1..3, "category": "identity|relationship|
    event|preference|project|voice", "statement": "...",
    "aliases": ["regexA", "regexB"],      # hit if ANY matches (case-insens.)
    "require": ["regexC"],                # optional: ALL must also match
    "scope": "profile|relationships|timeline|about"
  }],
  "antifacts": [{ "id": "...", "pattern": "regex", "scope": "...",
                  "note": "why this must not appear" }]
}

Tier weights make the eval hard to saturate: T1 (explicit, repeated) = 1,
T2 (single-thread, implicit) = 2, T3 (cross-thread inference) = 4. Composite
= 100 * weighted recall - antifact penalties. Tier-4 qualitative judgments
are scored by a strong-model judge, not this script.
"""
import json
import re
import sys

TIER_W = {1: 1, 2: 2, 3: 4}

args = sys.argv[1:]
misses_only = "--misses" in args
if misses_only:
    args.remove("--misses")
json_out = None
if "--json" in args:
    i = args.index("--json")
    json_out = args[i + 1]
    del args[i:i + 2]
profile_path = args[0]
key_path = args[1] if len(args) > 1 else "eval/groundtruth/key.json"

profile = open(profile_path, encoding="utf-8").read()
key = json.load(open(key_path, encoding="utf-8"))


def scoped(scope):
    if scope in (None, "", "profile"):
        return profile
    m = re.search(rf"^## {scope}\n(.*?)(?=^## |\Z)", profile, re.M | re.S | re.I)
    return m.group(1) if m else ""


def hit(item):
    text = scoped(item.get("scope"))
    if not text:
        return False
    if not any(re.search(a, text, re.I | re.S) for a in item["aliases"]):
        return False
    return all(re.search(r, text, re.I | re.S) for r in item.get("require", []))


rows, got_w, tot_w = [], 0.0, 0.0
by_tier = {}
for item in key["items"]:
    w = TIER_W[item["tier"]]
    h = hit(item)
    tot_w += w
    got_w += w * h
    t = by_tier.setdefault(item["tier"], [0, 0])
    t[0] += h
    t[1] += 1
    rows.append({"id": item["id"], "tier": item["tier"], "hit": h,
                 "category": item["category"], "statement": item["statement"]})

penalty = 0.0
anti_hits = []
for a in key.get("antifacts", []):
    if re.search(a["pattern"], scoped(a.get("scope")), re.I | re.S):
        anti_hits.append(a["id"])
        penalty += a.get("penalty", 3)

score = 100.0 * got_w / tot_w - penalty if tot_w else 0.0

for r in rows:
    if misses_only and r["hit"]:
        continue
    print(f"  {'HIT ' if r['hit'] else 'MISS'} T{r['tier']} {r['id']:34s} {r['statement'][:70]}")
for a in anti_hits:
    print(f"  ANTI {a}  (penalty)")
for t in sorted(by_tier):
    h, n = by_tier[t]
    print(f"tier {t}: {h}/{n}")
print(f"score: {score:.1f}  (weighted recall {100 * got_w / tot_w:.1f}"
      f"{f' - {penalty:.0f} penalty' if penalty else ''})")

if json_out:
    json.dump({"score": score, "recall": 100 * got_w / tot_w,
               "penalty": penalty, "tiers": by_tier, "items": rows,
               "antifacts": anti_hits}, open(json_out, "w"), indent=1)
