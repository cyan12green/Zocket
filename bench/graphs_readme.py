#!/usr/bin/env python3
"""Generate a focused 3-route HTTP benchmark graph for README.md:
Zocket vs nginx on echo, static (1K), and precompressed (.gz 8K)."""
import json, glob, statistics, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "bench/results/unified")
OUT = os.path.join(ROOT, "bench/graphs/readme_http.png")

CELLS = [
    ("h1_echo", "echo\n(POST 1 KB)"),
    ("static_small", "static\n(1 KB file)"),
    ("precompressed", "precompressed\n(.gz 8 KB)"),
]

def load(f):
    raw = open(f).read()
    d = json.loads(raw[raw.index("{"):])["result"]
    rps = d.get("rps", {}).get("mean", 0)
    tot = sum(d.get(k, 0) for k in ("req1xx","req2xx","req3xx","req4xx","req5xx"))
    return None if tot == 0 else rps

def cell_stats(cell, server):
    vals = []
    for f in glob.glob(f"{RES}/{cell}/{server}_r*.json"):
        try:
            v = load(f)
            if v: vals.append(v)
        except Exception: pass
    return statistics.median(vals) if vals else 0

labels, z_vals, n_vals = [], [], []
for cell, label in CELLS:
    labels.append(label)
    z_vals.append(cell_stats(cell, "zocket"))
    n_vals.append(cell_stats(cell, "nginx"))

fig, ax = plt.subplots(figsize=(8, 4.5))
x = range(len(labels))
w = 0.35
b1 = ax.bar([i - w / 2 for i in x], z_vals, w, label="Zocket", color="#2a9d8f")
b2 = ax.bar([i + w / 2 for i in x], n_vals, w, label="nginx 1.28", color="#e76f51")
for i, (z, n) in enumerate(zip(z_vals, n_vals)):
    if z: ax.text(i - w / 2, z * 1.01, f"{z/1000:.0f}k", ha="center", fontsize=9, fontweight="bold")
    if n: ax.text(i + w / 2, n * 1.01, f"{n/1000:.0f}k", ha="center", fontsize=9)
    ratio = z / n if n else 0
    if ratio > 1:
        ax.text(i, max(z, n) * 1.10, f"{ratio:.1f}x", ha="center", fontsize=9, color="#2a9d8f", fontweight="bold")
ax.set_xticks(list(x))
ax.set_xticklabels(labels, fontsize=10)
ax.set_ylabel("requests / second (median, 100 conns)")
ax.set_title("Zocket vs nginx — HTTP/1.1 (req/s, higher is better)", fontsize=12)
ax.legend(fontsize=10)
ax.spines[["top", "right"]].set_visible(False)
ax.set_ylim(0, max(max(z_vals), max(n_vals)) * 1.20)
plt.tight_layout()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
plt.savefig(OUT, dpi=120)
print(f"wrote {OUT}")
