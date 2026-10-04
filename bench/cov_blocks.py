#!/usr/bin/env python3
"""Exact per-file BLOCK coverage from .zcov files (zig-cov output).

zig-cov's JSON has no per-file block data, and its line numbers understate
straight-line code after untaken `try`s (documented zig-cov limitation).
Block counters are exact (a counter fired or it didn't), so this script
maps every instrumented PC back to its file with llvm-addr2line and reports
hit/total blocks per file — the gate metric for 90%+.

Usage: bench/cov_blocks.py [*.zcov]  (default: ./*.zcov)
"""
import struct
import subprocess
import sys
from collections import defaultdict


def read_zcov(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"ZCOV", path
    # NB: Header is `extern struct` (align 8): @sizeOf is 24, i.e. the
    # 22 bytes of fields plus 2 tail-padding bytes before BinPath.
    off = 24
    (ver,) = struct.unpack_from("<I", data, 4)
    (slide,) = struct.unpack_from("<q", data, 8)
    (n,) = struct.unpack_from("<I", data, 16)
    (plen,) = struct.unpack_from("<H", data, 20)
    binpath = data[off:off + plen].decode()
    off += plen
    pcs = struct.unpack_from("<%dQ" % n, data, off)
    off += 8 * n
    counts = data[off:off + n]
    assert len(counts) == n, (path, len(counts), n)
    return ver, slide, binpath, pcs, counts


def addrs_to_files(binary, addrs):
    """Batch llvm-addr2line: returns list of (function, file:line)."""
    inp = "\n".join("0x%x" % a for a in addrs)
    p = subprocess.run(
        ["llvm-addr2line-22", "-e", binary, "-f", "-C"],
        input=inp, capture_output=True, text=True)
    lines = p.stdout.splitlines()
    out = []
    for i in range(0, len(lines) - 1, 2):
        out.append((lines[i], lines[i + 1]))
    return out


def is_test_fn(fn):
    # Zig test symbols look like `compat.test.compat: file helpers...`.
    return ".test." in fn


def main(argv):
    paths = argv[1:] or __import__("glob").glob("*.zcov")
    if not paths:
        print("no .zcov files")
        return 1
    per_file = defaultdict(lambda: [0, 0])  # prod blocks: path -> [hit, total]
    per_file_test = defaultdict(lambda: [0, 0])  # test-body blocks (excluded)
    for zp in paths:
        ver, slide, binary, pcs, counts = read_zcov(zp)
        vas = [(pc - slide) & 0xFFFFFFFFFFFFFFFF for pc in pcs]
        locs = addrs_to_files(binary, vas)
        assert len(locs) == len(pcs), (zp, len(locs), len(pcs))
        for (fn, loc), c in zip(locs, counts):
            f = loc.split(":")[0]
            if f in ("??", ""):
                continue
            if "/Workspace/Zocket/" not in f or ".zig-cache" in f:
                continue
            short = f.split("/Workspace/Zocket/")[-1]
            if not (short.startswith("src/") or short in ("embeds.zig", "build.zig")):
                continue
            bucket = per_file_test if is_test_fn(fn) else per_file
            bucket[short][1] += 1
            if c:
                bucket[short][0] += 1
    for title, bucket in (("PROD", per_file), ("TEST bodies (excluded)", per_file_test)):
        th = sum(h for h, t in bucket.values())
        tt = sum(t for h, t in bucket.values())
        print("%s blocks: %.1f%% (%d/%d) across %d files" %
              (title, 100.0 * th / tt if tt else 100.0, th, tt, len(bucket)))
        if title != "PROD":
            continue
        rows = []
        for p, (h, t) in bucket.items():
            rows.append((100.0 * h / t if t else 100.0, h, t, p))
        rows = []
        for p, (h, t) in bucket.items():
            rows.append((100.0 * h / t if t else 100.0, h, t, p))
        rows.sort()
        for pct, h, t, p in rows:
            print("%-38s%6.1f%%  %d/%d" % (p, pct, h, t))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
