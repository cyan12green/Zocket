#!/usr/bin/env python3
"""Summarize benchmark JSON results into a markdown table.

Reads bench/results/<tag>_c<conns>_r<rep>.json files, computes the median of
rps.mean, latency p50/p95, latency mean and throughput across reps, and prints
a compact markdown table (also appended to BENCH.md via --doc).
"""
import json
import os
import statistics
import sys

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "bench/results"
TAG = sys.argv[2] if len(sys.argv) > 2 else ""
DOC = os.environ.get("BENCH_DOC", "bench/BENCH.md")


def ms(us: float) -> str:
    return f"{us / 1000.0:.2f} ms"


def mbs(bps: float) -> str:
    return f"{bps / 1e6:.2f} MB/s"


def summarize(files: list) -> dict:
    runs = []
    for f in files:
        with open(f) as fh:
            text = fh.read()
        # bombardier prepends terminal-progress lines before the JSON object.
        start = text.find("{")
        d = json.loads(text[start:])
        res = d["result"]
        runs.append(
            {
                "rps": res["rps"]["mean"],
                "p50": res["latency"]["percentiles"]["50"],
                "p95": res["latency"]["percentiles"]["95"],
                "mean": res["latency"]["mean"],
                "tput": res["bytesRead"] / res["timeTakenSeconds"],
                "count": res["others"],
            }
        )
    n = len(runs)
    return {
        "n": n,
        "rps": statistics.median(r["rps"] for r in runs),
        "p50": statistics.median(r["p50"] for r in runs),
        "p95": statistics.median(r["p95"] for r in runs),
        "mean": statistics.median(r["mean"] for r in runs),
        "tput": statistics.median(r["tput"] for r in runs),
    }


def by_conns(files: list) -> dict:
    grouped = {}
    for f in files:
        base = os.path.basename(f)
        if "_c" not in base:
            continue
        conns = base.split("_c")[1].split("_")[0]
        grouped.setdefault(int(conns), []).append(f)
    return dict(sorted(grouped.items()))


def main() -> int:
    if not TAG:
        print("usage: summarize.py <results_dir> <tag>")
        return 1
    files = [f for f in os.listdir(OUT_DIR) if f.startswith(TAG + "_c") and f.endswith(".json")]
    if not files:
        print(f"no results found for tag '{TAG}' in {OUT_DIR}")
        return 1
    grouped = by_conns(files)
    rows = []
    for conns, fl in grouped.items():
        s = summarize([os.path.join(OUT_DIR, f) for f in fl])
        rows.append((conns, s))
    print(f"\n## Benchmark results: {TAG}")
    print(f"| connections | reqs/sec | latency p50 | latency p95 | latency mean | throughput | reps |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for conns, s in rows:
        print(
            f"| {conns} | {s['rps']:.0f} | {ms(s['p50'])} | {ms(s['p95'])} | {ms(s['mean'])} | {mbs(s['tput'])} | {s['n']} |"
        )
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
