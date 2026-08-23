#!/usr/bin/env python3
"""Render the backlog benchmark: grouped bars (Zocket vs nginx req/s) per
feature cell, from bench/results/backlog/*.json. Output:
bench/graphs/backlog_compare.png"""
import json, glob, statistics, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "bench/results/backlog")
OUT = os.path.join(ROOT, "bench/graphs/backlog_compare.png")

CELLS = [
    ("headers", "headers\n(3 ops/req)"),
    ("auth_sha", "auth_basic\n({SHA})"),
    ("precompressed", "precompressed\n(.gz 8 KiB)"),
    ("cache_hit", "proxy_cache\n(HIT)"),
    ("limit_req", "limit_req\n(accepted)"),
]

def load(f):
    raw = open(f).read()
    d = json.loads(raw[raw.index("{"):])
    r = d.get("result", {})
    rps = r.get("rps", {}).get("mean", 0)
    total = sum(r.get(k, 0) for k in ("req1xx","req2xx","req3xx","req4xx","req5xx"))
    good = sum(r.get(k, 0) for k in ("req1xx","req2xx","req3xx"))
    if total == 0:
        return None  # crashed/dead server rep: exclude
    return rps, (good / total * 100 if total else 0)

def cell_stats(cell):
    rps = {"zocket": [], "nginx": []}
    ok = {"zocket": [], "nginx": []}
    for f in glob.glob(os.path.join(RES, cell, "*.json")):
        srv = "zocket" if "zocket" in os.path.basename(f) else "nginx"
        try:
            loaded = load(f)
        except Exception:
            continue
        if loaded is None:
            continue
        v, pct = loaded
        rps[srv].append(v)
        ok[srv].append(pct)
    return (statistics.median(rps["zocket"]) if rps["zocket"] else 0,
            statistics.median(rps["nginx"]) if rps["nginx"] else 0,
            statistics.median(ok["zocket"]) if ok["zocket"] else 0)

labels, z_vals, n_vals, notes = [], [], [], []
for cell, label in CELLS:
    z, n, ok_z = cell_stats(cell)
    labels.append(label)
    z_vals.append(z)
    n_vals.append(n)
    notes.append(f"{ok_z:.0f}% 2xx" if cell == "limit_req" else f"{z/n:.2f}x" if n else "")

fig, ax = plt.subplots(figsize=(10, 5.5))
x = range(len(labels))
w = 0.38
b1 = ax.bar([i - w / 2 for i in x], z_vals, w, label="Zocket", color="#2a9d8f")
b2 = ax.bar([i + w / 2 for i in x], n_vals, w, label="nginx 1.28", color="#e76f51")
for i, (z, n) in enumerate(zip(z_vals, n_vals)):
    if z: ax.text(i - w / 2, z * 1.01, f"{z:,.0f}", ha="center", fontsize=8)
    if n: ax.text(i + w / 2, n * 1.01, f"{n:,.0f}", ha="center", fontsize=8)
    if notes[i]: ax.text(i, max(z, n) * 1.08, notes[i], ha="center", fontsize=8, color="#555")
ax.set_xticks(list(x)); ax.set_xticklabels(labels)
ax.set_ylabel("requests / second (median, c=100)")
ax.set_title("Zocket backlog modules vs nginx — same endpoint, interleaved reps")
ax.legend()
ax.spines[["top", "right"]].set_visible(False)
plt.tight_layout()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
plt.savefig(OUT, dpi=120)
print(f"wrote {OUT}")
