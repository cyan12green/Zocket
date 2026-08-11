#!/usr/bin/env bash
# Real-capacity benchmark using the custom pipelined echo client.
#
# bombardier (an HTTP client) cannot drive this raw echo server past its own
# client-side limit (~3k req/s), so bench/echo-client.zig is used to measure
# server capacity: it opens N connections per client thread and runs
# request/echo round trips, verifying byte-exact echoes throughout.
#
# Usage: bench/bench2.sh <binary> <tag>
#   binary   path to the server executable
#   tag      result-file label (e.g. single_threaded, multi_threaded_4)
set -euo pipefail

BIN=${1:?usage: bench2.sh <binary> <tag> [extra-server-args...]}
TAG=${2:?usage: bench2.sh <binary> <tag>}
shift 2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/results"
PORT=${BENCH2_PORT:-8080}
CONNS=${BENCH2_CONNS:-50}
ITERS=${BENCH2_ITERS:-4000}
CLIENT_THREADS=${BENCH2_CLIENT_THREADS:-"8 16"}
REPS=${BENCH2_REPS:-3}
CLIENT="$ROOT/bench/echo_client"
if [ ! -x "$CLIENT" ]; then
    echo "building bench/echo_client..."
    (cd "$ROOT/bench" && zig build-exe echo-client.zig -OReleaseFast -femit-bin=echo_client)
fi

mkdir -p "$OUT"

"$BIN" "$@" >"$OUT/${TAG}.server.log" 2>&1 &
SRVPID=$!
trap 'kill $SRVPID 2>/dev/null || true' EXIT
sleep 0.5

for ct in $CLIENT_THREADS; do
    for r in $(seq 1 "$REPS"); do
        total=$((ct * CONNS * ITERS))
        line=$("$CLIENT" "$PORT" "$ct" "$CONNS" "$ITERS" 2>&1)
        echo "  threads=$ct rep=$r: $line"
        echo "$line" > "$OUT/${TAG}_ct${ct}_r${r}.txt"
    done
done

kill $SRVPID 2>/dev/null || true
wait $SRVPID 2>/dev/null || true
trap - EXIT
