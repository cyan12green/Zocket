#!/usr/bin/env bash
# Build the httpx.zig benchmarks from the third_party/httpx.zig submodule.
#
# The submodule is the pristine upstream checkout; this repo carries:
#   - bench/httpx-compat.patch  : local compatibility fixes so httpx.zig
#     compiles against the pinned Zig snapshot (0.16.0-dev.1503); re-applied
#     on top of every fresh submodule checkout
#   - bench/reqresp_bench_httpx.zig : the paired parse/build micro-benchmark
#   - bench/bench_server_httpx.zig  : the long-running HTTP server used by
#     the server-level comparison
#
# Outputs (into the submodule's zig-out/bin):
#   reqresp_bench   - request/response micro-benchmark
#   bench_server    - HTTP server (--port N)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HX="$ROOT/third_party/httpx.zig"
PATCH="$ROOT/bench/httpx-compat.patch"

if [ ! -e "$HX/.git" ]; then
    echo "submodule not initialized; run: git submodule update --init third_party/httpx.zig"
    exit 1
fi

cd "$HX"

# Apply the compatibility patch (idempotent).
if ! git apply --check "$PATCH" 2>/dev/null; then
    echo "compat patch already applied or conflicts; checking tree state..."
    git diff --stat | head -3
else
    git apply "$PATCH"
    echo "applied compat patch"
fi

# Our bench files are copied in (they live in the parent repo).
cp "$ROOT/bench/reqresp_bench_httpx.zig" bench/reqresp_bench.zig
cp "$ROOT/bench/bench_server_httpx.zig" examples/bench_server.zig

echo "building httpx benchmarks (ReleaseFast)..."
zig build -Doptimize=ReleaseFast example-reqresp_bench
zig build -Doptimize=ReleaseFast example-bench_server

echo "done: $HX/zig-out/bin/reqresp_bench and $HX/zig-out/bin/bench_server"
