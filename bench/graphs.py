#!/usr/bin/env python3
"""Single entry point for the benchmark suite and graph generation.

Usage:
  python3 bench/graphs.py            generate graphs from stored results
  python3 bench/graphs.py --run      run the full comparison suite first
                                     (matrix + static), then generate graphs

The whole flow is one program so CI can do: python3 bench/graphs.py --run.

Reads/writes:
  bench/results/servers/matrix/<cell>/A|B_<srv>_r*.json   (payload x conns)
  bench/results/servers/static/<cell>/A|B_<srv>_r*.json   (file serving)
  bench/graphs/*.png                                       (output)
"""
import argparse
import glob
import json
import os
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
    ("tcp", "Zocket", "#111111", 2.5),
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


def cell_value(d, tag, idx):
    a = med(d, f"A_{tag}")
    b = med(d, f"B_{tag}")
    if not a or not b:
        return None
    return statistics.median([a[idx], b[idx]])


def matrix_cells():
    cells = []
    sizes = {"1024": "1K", "8192": "8K", "65536": "64K"}
    for body in ("1024", "8192", "65536"):
        for c in ("10", "100", "1000"):
            cells.append((f"echo {sizes[body]} c={c}",
                          os.path.join(RESULTS, "matrix", f"b{body}_c{c}")))
    return cells


def static_cells():
    cells = []
    for size in ("1024", "1048576"):
        for c in ("100", "1000"):
            label = "1K" if size == "1024" else "1M"
            cells.append((f"static {label} c={c}",
                          os.path.join(RESULTS, "static", f"s{size}_c{c}")))
    return cells


def plot_matrix():
    sizes = {"1024": "1 KB", "8192": "8 KB", "65536": "64 KB"}
    for body, dirs in (("1024", []), ("8192", []), ("65536", [])):
        dirs = [os.path.join(RESULTS, "matrix", f"b{body}_c{c}") for c in ("10", "100", "1000")]
        xs = ("10", "100", "1000")
        fig, axes = plt.subplots(1, 2, figsize=(12, 4.2))
        for tag, name, color, lw in SERVERS:
            rps, p50 = [], []
            for d in dirs:
                r = cell_value(d, tag, 0)
                p = cell_value(d, tag, 1)
                rps.append(r)
                p50.append(p / 1000.0 if p else None)
            axes[0].plot(xs, rps, label=name, color=color, linewidth=lw, marker="o")
            axes[1].plot(xs, p50, label=name, color=color, linewidth=lw, marker="o")
        axes[0].set_title(f"POST /echo body={sizes[body]} — req/s (higher is better)")
        axes[0].set_xlabel("connections")
        axes[0].set_ylabel("requests/sec (higher is better)")
        axes[0].grid(True, alpha=0.3)
        axes[0].legend(fontsize=8)
        axes[1].set_title(f"POST /echo body={sizes[body]} — median latency (lower is better)")
        axes[1].set_xlabel("connections")
        axes[1].set_ylabel("p50 (ms, lower is better)")
        axes[1].grid(True, alpha=0.3)
        axes[1].legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(OUT, f"matrix_{body}.png"), dpi=120, bbox_inches="tight")
        plt.close(fig)
        print(f"matrix_{body}.png")


def plot_static():
    labels, zig, others = [], [], {s: [] for s, _, _, _ in SERVERS}
    for size, dirs in (("1024", []), ("1048576", [])):
        dirs = [os.path.join(RESULTS, "static", f"s{size}_c{c}") for c in ("100", "1000")]
        for d in dirs:
            conns = os.path.basename(d).split("_")[-1]
            labels.append(f"{'1K' if size == '1024' else '1M'} / c={conns}")
            for tag, _, _, _ in SERVERS:
                others[tag].append(cell_value(d, tag, 0) or 0)
    x = range(len(labels))
    width = 0.13
    fig, ax = plt.subplots(figsize=(11, 4.5))
    for i, (tag, name, color, lw) in enumerate(SERVERS):
        ax.bar([p + i * width for p in x], others[tag], width, label=name,
               color=color, edgecolor="black", linewidth=0.3)
    ax.set_xticks([p + width * (len(SERVERS) - 1) / 2 for p in x])
    ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylabel("requests/sec (higher is better)")
    ax.set_title("Static file serving — req/s (higher is better)")
    ax.legend(fontsize=8)
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "static.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)
    print("static.png")


def plot_nginx_compare():
    """One-to-one Zocket vs nginx across every cell: req/s bars and the
    derived per-request cost (1e9 / rps, ns/request)."""
    cells = matrix_cells() + static_cells()
    labels = [c[0] for c in cells]
    zig_rps, ngx_rps = [], []
    for _, d in cells:
        zig_rps.append(cell_value(d, "tcp", 0) or 0)
        ngx_rps.append(cell_value(d, "nginx", 0) or 0)
    zig_ns = [1e9 / r if r else 0 for r in zig_rps]
    ngx_ns = [1e9 / r if r else 0 for r in ngx_rps]

    x = range(len(labels))
    width = 0.38
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    axes[0].bar([p - width / 2 for p in x], zig_rps, width, label="Zocket",
                color="#111111")
    axes[0].bar([p + width / 2 for p in x], ngx_rps, width, label="nginx",
                color="#457b9d")
    axes[0].set_xticks(list(x))
    axes[0].set_xticklabels(labels, rotation=45, ha="right", fontsize=7)
    axes[0].set_ylabel("requests/sec (higher is better)")
    axes[0].set_title("Zocket vs nginx — req/s (higher is better)")
    axes[0].legend(fontsize=8)
    axes[0].grid(True, axis="y", alpha=0.3)

    axes[1].bar([p - width / 2 for p in x], [v / 1000 for v in zig_ns], width,
                label="Zocket", color="#111111")
    axes[1].bar([p + width / 2 for p in x], [v / 1000 for v in ngx_ns], width,
                label="nginx", color="#457b9d")
    axes[1].set_xticks(list(x))
    axes[1].set_xticklabels(labels, rotation=45, ha="right", fontsize=7)
    axes[1].set_ylabel("per-request cost (us, lower is better)")
    axes[1].set_title("Zocket vs nginx — effective cost per request (lower is better)")
    axes[1].legend(fontsize=8)
    axes[1].grid(True, axis="y", alpha=0.3)

    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "nginx_compare.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)
    print("nginx_compare.png")



def plot_h2_compare():
    """HTTP/2 echo/static, Zocket vs nginx (h2load results from bench/results/h2)."""
    h2dir = os.path.join(ROOT, "bench", "results", "h2")
    workloads = [
        ("echo100", "GET /echo\nm=100 streams"),
        ("echo1", "GET /echo\nm=1 stream"),
        ("static100", "GET /static\nm=100 streams"),
    ]
    if not os.path.isdir(h2dir):
        print("h2_compare.png: no bench/results/h2 data (run bench/h2bench.sh first)")
        return
    labels = []
    z_meds, n_meds = [], []
    for wl, label in workloads:
        zv = _h2_med(h2dir, f"{wl}_z.txt")
        nv = _h2_med(h2dir, f"{wl}_n.txt")
        if zv is None or nv is None:
            print(f"h2_compare.png: missing {wl} data, skipping")
            return
        labels.append(label)
        z_meds.append(zv)
        n_meds.append(nv)

    x = list(range(len(labels)))
    width = 0.35
    fig, ax = plt.subplots(figsize=(10, 4.5))
    bars = []
    bars += ax.bar([p - width / 2 for p in x], z_meds, width, label="Zocket", color="#111111")
    bars += ax.bar([p + width / 2 for p in x], n_meds, width, label="nginx", color="#b22222")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_title("HTTP/2 (h2c) — Zocket vs nginx, h2load, 4 connections (req/s, higher is better)", fontsize=11)
    ax.set_ylabel("req/s")
    for bar, v in zip(bars, z_meds + n_meds):
        ax.text(bar.get_x() + bar.get_width() / 2, v, f"{v:,.0f}",
                ha="center", va="bottom", fontsize=7)
    ax.legend(fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    ax.ticklabel_format(axis="y", style="sci", scilimits=(4, 4))
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "h2_compare.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)
    print("h2_compare.png")


def plot_tls_compare():
    """HTTP/2 over TLS, Zocket vs nginx (h2load results from bench/results/tls)."""
    tdir = os.path.join(ROOT, "bench", "results", "tls")
    workloads = [
        ("empty100", "GET /\nm=100 streams"),
        ("echo100", "GET /echo\nm=100 streams"),
        ("echo1", "GET /echo\nm=1 stream"),
        ("static100", "GET /static\nm=100 streams"),
    ]
    if not os.path.isdir(tdir):
        print("tls_compare.png: no bench/results/tls data (run bench/tlsbench.sh first)")
        return
    labels = []
    z_meds, n_meds = [], []
    for wl, label in workloads:
        zv = _h2_med(tdir, f"{wl}_z.txt")
        nv = _h2_med(tdir, f"{wl}_n.txt")
        if zv is None or nv is None:
            print(f"tls_compare.png: missing {wl} data, skipping")
            return
        labels.append(label)
        z_meds.append(zv)
        n_meds.append(nv)

    x = list(range(len(labels)))
    width = 0.35
    fig, ax = plt.subplots(figsize=(10, 4.5))
    bars = []
    bars += ax.bar([p - width / 2 for p in x], z_meds, width, label="Zocket", color="#111111")
    bars += ax.bar([p + width / 2 for p in x], n_meds, width, label="nginx", color="#b22222")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_title("HTTP/2 over TLS (h2 via ALPN) — Zocket vs nginx, h2load, 4 connections (req/s, higher is better)", fontsize=11)
    ax.set_ylabel("req/s")
    for bar, v in zip(bars, z_meds + n_meds):
        ax.text(bar.get_x() + bar.get_width() / 2, v, f"{v:,.0f}",
                ha="center", va="bottom", fontsize=7)
    ax.legend(fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    ax.ticklabel_format(axis="y", style="sci", scilimits=(4, 4))
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "tls_compare.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)
    print("tls_compare.png")


def _h2_med(h2dir, name):
    """Median of the per-rep req/s values; None when no valid data."""
    path = os.path.join(h2dir, name)
    if not os.path.isfile(path):
        return None
    vals = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            v = float(line)
        except ValueError:
            continue
        if v > 1000:
            vals.append(v)
    if not vals:
        return None
    return statistics.median(vals)



def plot_chunked_compare():
    """HTTP/1.1 chunked transfer (POST echo), Zocket vs nginx (bombardier
    results from bench/results/chunked)."""
    cdir = os.path.join(ROOT, "bench", "results", "chunked")
    if not os.path.isdir(cdir):
        print("chunked_compare.png: no bench/results/chunked data (run bench/chunked-bench.sh first)")
        return
    labels, z_meds, n_meds = [], [], []
    for body in (128, 8192):
        for conns in (10, 100, 1000):
            zv = _h2_med(cdir, f"b{body}_c{conns}_z.txt")
            nv = _h2_med(cdir, f"b{body}_c{conns}_n.txt")
            if zv is None or nv is None:
                print(f"chunked_compare.png: missing b{body}_c{conns} data, skipping")
                return
            labels.append(f"{body} B\nc={conns}")
            z_meds.append(zv)
            n_meds.append(nv)

    x = list(range(len(labels)))
    width = 0.35
    fig, ax = plt.subplots(figsize=(10, 4.5))
    bars = []
    bars += ax.bar([p - width / 2 for p in x], z_meds, width, label="Zocket", color="#111111")
    bars += ax.bar([p + width / 2 for p in x], n_meds, width, label="nginx", color="#b22222")
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_title("HTTP/1.1 chunked transfer — Zocket vs nginx, POST echo (req/s, higher is better)", fontsize=11)
    ax.set_ylabel("req/s")
    for bar, v in zip(bars, z_meds + n_meds):
        ax.text(bar.get_x() + bar.get_width() / 2, v, f"{v:,.0f}",
                ha="center", va="bottom", fontsize=7)
    ax.legend(fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)
    ax.ticklabel_format(axis="y", style="sci", scilimits=(4, 4))
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "chunked_compare.png"), dpi=120, bbox_inches="tight")
    plt.close(fig)
    print("chunked_compare.png")


def run_suite():
    print("== running the comparison suite ==")
    subprocess.run(["bash", "bench/compare-servers.sh",
                    "--matrix", "--bodies", "1024 8192 65536",
                    "--conns-list", "10 100 1000",
                    "--reps", "3", "--duration", "5s"], cwd=ROOT, check=True)
    subprocess.run(["bash", "bench/compare-servers.sh",
                    "--static", "1024 1048576",
                    "--conns-list", "100 1000",
                    "--reps", "3", "--duration", "5s"], cwd=ROOT, check=True)


def main():
    ap = argparse.ArgumentParser(description="Run the suite and/or generate graphs")
    ap.add_argument("--run", action="store_true",
                    help="run the full comparison suite first, then generate graphs")
    args = ap.parse_args()
    if args.run:
        run_suite()
    os.makedirs(OUT, exist_ok=True)
    plot_matrix()
    plot_static()
    plot_nginx_compare()
    plot_h2_compare()
    plot_tls_compare()
    plot_chunked_compare()
    print("done")


if __name__ == "__main__":
    main()
