#!/usr/bin/env python3
"""Render unified results: grouped bars per cell (all servers) ->
bench/graphs/unified_web.png"""
import json, glob, statistics, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "bench/results/unified")
OUT = os.path.join(ROOT, "bench/graphs/unified_web.png")

COLORS = {"zocket": "#2a9d8f", "nginx": "#e76f51", "haproxy": "#457b9d", "envoy": "#8d5a97"}

def load(f):
    raw = open(f).read()
    d = json.loads(raw[raw.index("{"):])["result"]
    rps = d.get("rps", {}).get("mean", 0)
    tot = sum(d.get(k, 0) for k in ("req1xx","req2xx","req3xx","req4xx","req5xx"))
    return None if tot == 0 else rps

cells = sorted({os.path.basename(os.path.dirname(f)) for f in glob.glob(f"{RES}/*/*.json")})
servers = sorted({os.path.basename(f).split("_r")[0]
                  for f in glob.glob(f"{RES}/*/*.json")})
data = {s: [] for s in servers}
labels = []
for cell in cells:
    labels.append(cell)
    for srv in servers:
        vals = []
        for f in glob.glob(f"{RES}/{cell}/{srv}_r*.json"):
            try:
                v = load(f)
                if v: vals.append(v)
            except Exception: pass
        data[srv].append(statistics.median(vals) if vals else 0)

fig, ax = plt.subplots(figsize=(1.6 * len(cells) + 2, 5.5))
x = range(len(cells))
w = 0.8 / max(len(servers), 1)
for i, srv in enumerate(servers):
    ax.bar([xi + i * w for xi in x], data[srv], w, label=srv, color=COLORS.get(srv))
    for xi, v in zip(x, data[srv]):
        if v: ax.text(xi + i * w, v * 1.01, f"{v/1000:.0f}k", ha="center", fontsize=7)
ax.set_xticks(list(x)); ax.set_xticklabels(labels, fontsize=9)
ax.set_ylabel("requests / second (median)")
ax.set_title("Unified benchmark — webserver / fileserver / LB")
ax.legend(); ax.spines[["top","right"]].set_visible(False)
plt.tight_layout()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
plt.savefig(OUT, dpi=120)
print("wrote", OUT)
