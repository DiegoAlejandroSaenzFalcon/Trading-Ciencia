from __future__ import annotations

import csv
import hashlib
import re
from pathlib import Path

ROOT = Path(r"C:\Users\Diego Saenz\OneDrive\Diego\Experts")
OUT = Path(r"C:\Proyectos\Trading-Ciencia\research\projects\mt5\03-analysis")
EXCLUDED = {"Advisors", "Examples", "Free Robots", "Market"}
SIMILARITY_THRESHOLD = 0.55


def family(name):
    n = name.lower()
    rules = [
        ("apexquant", r"apexquant|aqds"),
        ("neur_algo", r"neuralgo"),
        ("fenix-mt5", r"fenix"),
        ("trendsniper", r"trendsniper"),
        ("quantum-queen", r"quantum.?queen"),
        ("akali", r"akali"),
        ("gold-ict", r"goldict|orderblock"),
        ("gold-breakout", r"breakout"),
        ("engulfing", r"engulfing"),
        ("zrce", r"zrce"),
        ("satoshi", r"satoshi"),
        ("smc", r"ultimate.?smc|smc"),
        ("oro-gold", r"^oro|mql5 oro|gold edition"),
    ]
    for fam, pat in rules:
        if re.search(pat, n):
            return fam
    if re.search(r"diagnost|core_sensor|^multi$|^test$|^prueba$|^mama$|^papa$", n):
        return "diagnostic-or-experiment"
    return "other"


def tokens(text):
    text = re.sub(r"//.*?$", "", text, flags=re.M)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", text.lower()))


rows = []
for p in ROOT.rglob("*.mq5"):
    if any(part in EXCLUDED for part in p.relative_to(ROOT).parts):
        continue
    t = p.read_text(encoding="utf-8-sig", errors="replace")
    rows.append(
        {
            "filename": p.name,
            "relative_path": p.relative_to(ROOT).as_posix(),
            "family": family(p.name),
            "lines": len(t.splitlines()),
            "inputs": len(re.findall(r"(?m)^\s*input\b", t)),
            "normalized_sha256": hashlib.sha256(re.sub(r"\s+", "", t).lower().encode()).hexdigest(),
            "tokens": tokens(t),
        }
    )
rows.sort(key=lambda x: x["filename"].lower())

with (OUT / "MT5-FAMILY-INVENTORY.csv").open("w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(
        f,
        fieldnames=["filename", "relative_path", "family", "lines", "inputs", "normalized_sha256"],
    )
    w.writeheader()
    for r in rows:
        w.writerow({k: r[k] for k in w.fieldnames})

pairs = []
for i, a in enumerate(rows):
    for b in rows[i + 1 :]:
        if a["family"] == "other" and b["family"] == "other":
            continue
        inter = len(a["tokens"] & b["tokens"])
        union = len(a["tokens"] | b["tokens"])
        sim = inter / union if union else 0
        if sim >= SIMILARITY_THRESHOLD:
            pairs.append((sim, a["filename"], b["filename"], a["family"], b["family"]))
pairs.sort(reverse=True)

with (OUT / "MT5-SIMILARITY-CANDIDATES.csv").open("w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["token_jaccard", "file_a", "file_b", "family_a", "family_b"])
    for p in pairs[:200]:
        w.writerow([f"{p[0]:.4f}", *p[1:]])

counts = {}
for r in rows:
    counts[r["family"]] = counts.get(r["family"], 0) + 1
lines = [
    "# MT5 family and similarity analysis",
    "",
    "Analyzed source files: **" + str(len(rows)) + "**",
    "",
    "## Family counts",
    "",
    "| Family | Files |",
    "|---|---:|",
]
for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
    lines.append(f"| {k} | {v} |")
lines += [
    "",
    "## Similarity candidates",
    "",
    "Token Jaccard is used for scalable screening. It is a candidate signal, not proof of lineage.",
    "",
    "| Similarity | File A | File B |",
    "|---:|---|---|",
]
for sim, a, b, _fa, _fb in pairs[:80]:
    lines.append(f"| {sim:.3f} | {a} | {b} |")
(OUT / "MT5-FAMILY-AND-SIMILARITY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("Analyzed " + str(len(rows)) + " sources; similarity candidates: " + str(len(pairs)))
