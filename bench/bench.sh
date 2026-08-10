#!/usr/bin/env bash
# Reproducible echo-server benchmark harness.
#
# Usage: bench/bench.sh <binary> <tag> [bombardier-args...]
#   binary   path to the server executable to benchmark
#   tag      label used in result file names (e.g. "single_threaded", "multi_threaded_8")
#
# Requires bombardier >= v1.2 (https://github.com/codesenberg/bombardier), plus
# python3 for result summarization.
#
# Protocol note: the server under test is a raw byte-echo server. It returns
# the request bytes unchanged, so bombardier (an HTTP client) reports every
# request as an HTTP response-parse error. The reported Reqs/sec, latency and
# throughput nevertheless measure real request/response round trips; the
# relative comparison between builds is what matters. bench/echo-check.py
# independently verifies byte-level echo correctness under the same load.
set -euo pipefail

BIN=${1:?usage: bench.sh <binary> <tag>}
TAG=${2:?usage: bench.sh <binary> <tag>}
shift 2

BOMB=${BOMB:-$HOME/go/bin/bombardier}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/results"
PORT=${BENCH_PORT:-8080}
DURATION=${BENCH_DURATION:-10s}
CONNECTIONS=${BENCH_CONNECTIONS:-"10 100 500"}
REPS=${BENCH_REPS:-3}

mkdir -p "$OUT"

echo "== Starting server $BIN (tag=$TAG) on :$PORT =="
"$BIN" >"$OUT/${TAG}.server.log" 2>&1 &
SRVPID=$!
trap 'kill $SRVPID 2>/dev/null || true' EXIT
sleep 0.5

python3 "$ROOT/bench/echo-check.py" "$PORT" || { echo "echo-check FAILED; aborting"; exit 1; }

for c in $CONNECTIONS; do
    for r in $(seq 1 "$REPS"); do
        file="$OUT/${TAG}_c${c}_r${r}.json"
        "$BOMB" -c "$c" -d "$DURATION" -l -o json "http://127.0.0.1:$PORT/" >"$file" 2>/dev/null
        echo "  recorded $c conns, rep $r"
    done
done

kill $SRVPID 2>/dev/null || true
wait $SRVPID 2>/dev/null || true
trap - EXIT

python3 "$ROOT/bench/summarize.py" "$OUT" "$TAG" "$PORT"
