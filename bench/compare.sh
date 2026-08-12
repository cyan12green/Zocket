#!/usr/bin/env bash
# Run the paired request/response micro-benchmark matrix (tcp-server vs
# httpx.zig submodule) and print a comparison table.
#
#   bench/compare.sh [--iters N] [--rounds N] [--req NAME] [--resp NAME]
#
# Builds both benches (httpx side via build-httpx.sh), runs them with the
# same parameters, and prints a markdown table: ns/op and ops/sec for every
# request-parse and response-build variant, plus the tcp/httpx ratio.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERS=100000
ROUNDS=5
REQ=""
RESP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --iters) ITERS="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --req) REQ="$2"; shift 2 ;;
        --resp) RESP="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

echo "== building tcp-server bench =="
mkdir -p "$ROOT/zig-out/bin"
(cd "$ROOT" && zig build-exe -OReleaseFast \
    -femit-bin="$ROOT/zig-out/bin/reqresp_bench" \
    --dep tcp_server --dep embeds \
    -Mroot=bench/reqresp_bench.zig -Mtcp_server=src/root.zig -Membeds=embeds.zig)

echo "== building httpx.zig bench (submodule) =="
bash "$ROOT/bench/build-httpx.sh" >/dev/null

HX_BENCH="$ROOT/third_party/httpx.zig/zig-out/bin/reqresp_bench"

ARGS="--iters $ITERS --rounds $ROUNDS"
[ -n "$REQ" ] && ARGS="$ARGS --req $REQ"
[ -n "$RESP" ] && ARGS="$ARGS --resp $RESP"

echo "== running (iters=$ITERS rounds=$ROUNDS req='${REQ:-all}' resp='${RESP:-all}') =="
TCP_OUT=$("$ROOT/zig-out/bin/reqresp_bench" $ARGS 2>&1)
HX_OUT=$("$HX_BENCH" $ARGS 2>&1)

echo "$TCP_OUT"
echo "---"
echo "$HX_OUT"
echo "== comparison =="

python3 - "$TCP_OUT" "$HX_OUT" <<'EOF'
import re, sys

tcp = sys.argv[1]
hx = sys.argv[2]

def parse(out):
    rows = {}
    for line in out.splitlines():
        m = re.match(r'\s*(request_parse|response_build)\[([^\]]+)\]\s+.*avg=([0-9.]+)ns/op.*throughput=([0-9]+) ops/sec', line)
        if m:
            rows[(m.group(1), m.group(2))] = (float(m.group(3)), int(m.group(4)))
    return rows

t = parse(tcp)
h = parse(hx)

print("| op | variant | tcp-server ns/op | httpx.zig ns/op | ratio (tcp faster) |")
print("|---|---:|---:|---:|---:|")
for key in sorted(t.keys()):
    if key not in h:
        continue
    tns, tops = t[key]
    hns, hops = h[key]
    ratio = hns / tns if tns > 0 else float('inf')
    print(f"| {key[0]} | {key[1]} | {tns:.0f} | {hns:.0f} | {ratio:.0f}x |")
EOF
