#!/usr/bin/env python3
"""Summarize bench2 (echo client) results into a markdown table.

Reads bench/results/<tag>_ct<threads>_r<rep>.txt lines of the form
"requests=N bad=B time=T rps=R" and prints the median rps per client-thread
count per tag.
"""
import os
import re
import statistics
import sys

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "bench/results"
TAGS = sys.argv[2:] or ["single_threaded", "multi_threaded_2", "multi_threaded_4", "multi_threaded_8"]

LINE_RE = re.compile(r"requests=(\d+) bad=(\d+) time=([\d.]+)s rps=([\d.]+)")


def collect(tag: str) -> dict:
    grouped = {}
    for f in sorted(os.listdir(OUT_DIR)):
        if not f.startswith(tag + "_ct"):
            continue
        ct = f.split("_ct")[1].split("_")[0]
        with open(os.path.join(OUT_DIR, f)) as fh:
            m = LINE_RE.search(fh.read())
        if not m:
            continue
        grouped.setdefault(int(ct), []).append(float(m.group(4)))
    return {ct: statistics.median(v) for ct, v in grouped.items()}


def main() -> int:
    data = {}
    for tag in TAGS:
        data[tag] = collect(tag)
    all_cts = sorted({ct for d in data.values() for ct in d})
    print("\n## echo-client throughput (median req/s, byte-exact echo verified)")
    print("| config | " + " | ".join(f"{ct} threads" for ct in all_cts) + " |")
    print("|---|" + "---|" * len(all_cts))
    for tag in TAGS:
        row = data.get(tag, {})
        print("| " + tag + " | " + " | ".join(f"{row.get(ct, 0):.0f}" for ct in all_cts) + " |")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
