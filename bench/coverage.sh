#!/usr/bin/env bash
# Coverage in one command: `zig build cov` (see build.zig).
#
# Primary path is zig-cov (SanitizerCoverage instrumentation — exact line
# and block numbers, no ptrace breakpoints):
#   https://github.com/ericsssan/zcov
# Build it once with `zig build -Doptimize=ReleaseSafe` inside the zcov
# checkout, then put `zig-cov` and `zig-cov-rt.o` on PATH (same directory).
# This script runs `zig-cov test` (summary) and also writes
# bench/.cache/coverage.json for scripting / CI gates.
#
# Fallback: per-area kcov runs over the src/cov_*.zig split drivers
# (the monolithic test binary exceeds kcov's breakpoint capacity).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p bench/.cache

if command -v zig-cov >/dev/null 2>&1; then
    echo "== coverage: zig-cov =="
    zig-cov test --format=json --output=bench/.cache/coverage.json
    zig-cov report --format=summary bench/.cache/coverage.json 2>/dev/null || true
    python3 - <<'PYEOF'
import json
d = json.load(open("bench/.cache/coverage.json"))
s = d.get("summary", {})
print("lines: %.1f%% (%d/%d)  blocks: %.1f%% (%d/%d)" % (
    s.get("line_percent", 0), s.get("lines_hit", 0), s.get("lines_found", 0),
    s.get("block_percent", 0), s.get("blocks_hit", 0), s.get("blocks_found", 0)))
PYEOF
    exit 0
fi

echo "zig-cov not found on PATH; attempting per-area kcov fallback..." >&2
command -v kcov >/dev/null 2>&1 || {
    echo "coverage.sh: FAIL: need zig-cov (preferred) or kcov on PATH." >&2
    echo "  zig-cov: build https://github.com/ericsssan/zcov and put" >&2
    echo "  zig-cov + zig-cov-rt.o on PATH." >&2
    exit 1
}
rm -rf bench/.cache/kcov && mkdir -p bench/.cache/kcov
for drv in src/cov_*.zig; do
    name="$(basename "$drv" .zig)"
    bin="bench/.cache/kcov-$name"
    zig test --dep embeds --dep config_options -Mroot="$drv" \
        -Membeds=embeds.zig -Mconfig_options=src/cov_options.zig \
        -femit-bin="$bin" >/dev/null
    kcov --include-pattern='src/' "bench/.cache/kcov/$name" "$bin" >/dev/null 2>&1 || true
done
kcov --merge bench/.cache/kcov/* bench/.cache/kcov-merged 2>/dev/null || true
echo "kcov fallback done: bench/.cache/kcov/"
