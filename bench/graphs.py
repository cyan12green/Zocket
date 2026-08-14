#!/usr/bin/env python3
"""Generate benchmark graphs from the stored results.

Reads:
  bench/results/servers/matrix/<cell>/A|B_<srv>_r*.json   (payload x conns)
  bench/results/servers/static/<cell>/A|B_<srv>_r*.json   (file serving)
  bench/compare.sh output (micro-benchmarks, run on demand)

Writes PNGs into bench/graphs/ (referenced from the README):
  matrix_reqs_<size>.png   req/s vs connections, one line per server
  matrix_p50_<size>.png    median latency vs connections
  static.png               req/s grouped bars per file size
  micro_parse.png, micro_build.png   ns/op per variant (Ziglet vs httpx.zig)
"""
import glob
import json
import os
import re
import statistics
import subprocess
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "bench", "results", "servers")
OUT = os.path.join(ROOT, "bench", "graphs")

SERVERS = [
    ("tcp", "Ziglet", "#111111", 2.5),
    ("actix", "actix-web", "#e63946", 1.6),
    ("nginx", "nginx", "#457b9d", 1.6),
    ("bun", "Bun.serve", "#f4a261", 1.6),
    ("caddy", "Caddy", "#2a9d8f", 1.6),
    ("hx", "httpx.zig", "#8d99ae", 1.6),
]


def med(d, name):
    vals = []
    for f in sorted(glob.glob(os.path.join(d, f"{name}_r*.json"))):
        try:
            text = open(f).read()
            j = json.loads(text[text.find("{"):])
            r = j["result"]
            vals.append((r["rps"]["mean"], r["latency"]["percentiles"]["50"]))
        except Exception:
            pass
    if not vals:
        return None
    return statistics.median(v[0] for v in vals), statistics.median(v[1] for v in vals)


def cells():
    out = []
    for body in ("1024", "8192", "65536"):
        row = []
        for c in ("10", "100", "1000"):
            row.append(os.path.join(RESULTS, "matrix", f"b{body}_c{c}"))
        out.append((body, row))
    return out


def static_cells():
    out = []
    for size in ("1024", "1048576"):
        row = []
        for c in ("100", "1000"):
            row.append(os.path.join(RESULTS, "static", f"s{size}_c{c}"))
        out.append((size, row))
    return out


def plot_matrix():
    sizes = {"1024": "1 KB", "8192": "8 KB", "65536": "64 KB"}
    for body, dirs in cells():
        xs = ("10", "100", "1000")
        fig, axes = plt.subplots(1, 2, figsize=(12, 4.2))
        for tag, name, color, lw in SERVERS:
            rps, p50 = [], []
            for d in dirs:
                m = med(d, f"A_{tag}")
                b = med(d, f"B_{tag}")
                if m and b:
                    rps.append(statistics.median([m[0], b[0]]))
                    p50.append(statistics.median([m[1], b[1]]))
                else:
                    rps.append(None)
                    p50.append(None)
            axes[0].plot(xs, rps, label=name, color=color, linewidth=lw, marker="o")
            axes[1].plot(xs, [p / 1000.0 if p else None for p in p50],
                         label=name, color=color, linewidth=lw, marker="o")
        axes[0].set_title(f"POST /echo body={sizes[body]} — req/s")
        axes[0].set_xlabel("connections")
        axes[0].set_ylabel("requests/sec")
        axes[0].grid(True, alpha=0.3)
        axes[0].legend(fontsize=8)
        axes[1].set_title(f"POST /echo body={sizes[body]} — median latency")
        axes[1].set_xlabel("connections")
        axes[1].set_ylabel("p50 (ms)")
        axes[1].grid(True, alpha=0.3)
        axes[1].legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(OUT, f"matrix_{body}.png"), dpi=120)
        plt.close(fig)
        print(f"matrix_{body}.png")


def plot_static():
    labels = []
    zig = []
    others = {srv: [] for srv, _, _, _ in SERVERS}
    for size, dirs in static_cells():
        for d in dirs:
            conns = os.path.basename(d).split("_")[-1]
            labels.append(f"{size} B / c={conns}")
            for tag, _, _, _ in SERVERS:
                m = med(d, f"A_{tag}")
                b = med(d, f"B_{tag}")
                val = statistics.median([m[0], b[0]]) if m and b else 0
                others[tag].append(val)
    x = range(len(labels))
    width = 0.13
    fig, ax = plt.subplots(figsize=(11, 4.5))
    for i, (tag, name, color, lw) in enumerate(SERVERS):
        vals = others[tag]
        ax.bar([p + i * width for p in x], vals, width, label=name, color=color,
               edgecolor="black", linewidth=0.3)
    ax.set_xticks([p + width * (len(SERVERS) - 1) / 2 for p in x])
    ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylabel("requests/sec")
    ax.set_title("Static file serving — req/s")
    ax.legend(fontsize=8)
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "static.png"), dpi=120)
    plt.close(fig)
    print("static.png")


def parse_micro(out):
    """compare.sh output -> dict variant -> (ziglet_ns, httpx_ns)."""
    data = {}
    current = None
    ziglet = True
    for line in out.splitlines():
        m = re.search(r"(request_parse|response_build)\[(\w+)\].*avg=([\d.]+)ns/op", line)
        if m:
            key = (m.group(1), m.group(2))
            data.setdefault(key, {})["ziglet" if "httpx" not in line else "httpx"] = float(m.group(3))
    return data


def plot_micro():
    res = subprocess.run(["bash", "bench/compare.sh"], cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        print("micro bench failed; skipping micro graphs")
        return
    data = parse_micro(res.stdout)
    for op, title, fname in (
        ("request_parse", "Request parsing — avg ns/op", "micro_parse.png"),
        ("response_build", "Response building — avg ns/op", "micro_build.png"),
    ):
        items = sorted((k[1] for k in data if k[0] == op))
        zig = [data[(op, v)]["ziglet"] for v in items]
        hx = [data[(op, v)].get("httpx", 0) for v in items]
        fig, ax = plt.subplots(figsize=(9, 4))
        x = range(len(items))
        ax.bar([p - 0.2 for p in x], zig, 0.4, label="Ziglet", color="#111111")
        ax.bar([p + 0.2 for p in x], hx, 0.4, label="httpx.zig", color="#8d99ae")
        ax.set_xticks(list(x))
        ax.set_xticklabels(items, fontsize=9)
        ax.set_ylabel("ns/op (lower is better)")
        ax.set_title(title)
        ax.legend()
        ax.grid(True, axis="y", alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(OUT, fname), dpi=120)
        plt.close(fig)
        print(fname)


def main():
    os.makedirs(OUT, exist_ok=True)
    plot_matrix()
    plot_static()
    plot_micro()
    print("done")


if __name__ == "__main__":
    main()
