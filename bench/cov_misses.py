#!/usr/bin/env python3
"""Mine uncovered line ranges from bench/.cache/coverage.json.

Usage:
  bench/cov_misses.py [file-substr ...] [--top N] [--min LEN]

Prints, per project file, the missed-line ranges (biggest first) with the
source context of each range. With no args, prints the per-file summary
table sorted worst-first. Exit 0 always (reporting only).
"""
import json
import subprocess
import sys

JSON = "bench/.cache/coverage.json"


def load():
    with open(JSON) as f:
        return json.load(f)


def proj_files(d):
    out = []
    for f in d["files"]:
        p = f["path"]
        if "/Workspace/Zocket/" in p and ".zig-cache" not in p:
            short = p.split("/Workspace/Zocket/")[-1]
            if short.startswith("src/") or short == "embeds.zig":
                out.append((short, f))
    return out


def ranges(missed):
    if not missed:
        return []
    missed = sorted(missed)
    out = []
    s = p = missed[0]
    for x in missed[1:]:
        if x == p + 1:
            p = x
        else:
            out.append((s, p))
            s = p = x
    out.append((s, p))
    return out


def context(short, s, p, radius=0):
    try:
        with open(short) as f:
            lines = f.readlines()
        lo = max(1, s - radius)
        hi = min(len(lines), p + radius)
        return "".join("%4d| %s" % (n, lines[n - 1]) for n in range(lo, hi + 1))
    except OSError:
        return "<source unavailable>\n"


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    top = 12
    minlen = 1
    for a in argv[1:]:
        if a.startswith("--top="):
            top = int(a.split("=")[1])
        if a.startswith("--min="):
            minlen = int(a.split("=")[1])
    d = load()
    files = proj_files(d)
    if not args:
        rows = []
        tf = th = 0
        for short, f in files:
            lf, lh = int(f["lines_found"]), int(f["lines_hit"])
            tf += lf
            th += lh
            rows.append((100.0 * lh / lf if lf else 100.0, lh, lf, short))
        print("PROJECT lines: %.1f%% (%d/%d)" % (100.0 * th / tf, th, tf))
        rows.sort()
        for pct, h, t, p in rows:
            print("%-38s%6.1f%%  %d/%d" % (p, pct, h, t))
        return
    for short, f in files:
        if not any(a in short for a in args):
            continue
        missed = sorted(l["line"] for l in f["lines"] if l["hits"] == 0)
        print("== %s  %.1f%% (%s/%s), %d missed lines" %
              (short, 100.0 * int(f["lines_hit"]) / int(f["lines_found"]),
               f["lines_hit"], f["lines_found"], len(missed)))
        big = [r for r in ranges(missed) if r[1] - r[0] + 1 >= minlen]
        big.sort(key=lambda r: r[1] - r[0], reverse=True)
        for s, p in big[:top]:
            tag = "%d-%d (%d)" % (s, p, p - s + 1) if s != p else "%d" % s
            print("--- lines %s ---" % tag)
            print(context(short, s, p), end="")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
