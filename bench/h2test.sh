#!/usr/bin/env bash
# HTTP/2 end-to-end integration tests (Milestone 16): run the real server
# and verify it against a known client (curl --http2-prior-knowledge) and
# the h2spec RFC-conformance suite. Fails loudly so a regression is caught.
#
# Usage: bash bench/h2test.sh   (or: zig build h2test)
#
# Requires: curl with HTTP/2 support (libcurl + nghttp2) and h2spec
# (go install github.com/summerwind/h2spec/cmd/h2spec@latest).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${H2TEST_PORT:-18145}"
BIN="$ROOT/zig-out/bin/zocket"
H2SPEC="${H2SPEC:-$HOME/go/bin/h2spec}"
MIN_PASS="${H2TEST_MIN_PASS:-130}" # of 145 h2spec tests (142 run, 4 skipped)

command -v curl >/dev/null || { echo "h2test: curl not found"; exit 1; }
curl --version 2>/dev/null | grep -q "nghttp2" || { echo "h2test: curl lacks HTTP/2 (nghttp2) support"; exit 1; }
[ -x "$H2SPEC" ] || { echo "h2test: h2spec not found at $H2SPEC (go install github.com/summerwind/h2spec/cmd/h2spec@latest)"; exit 1; }

echo "== h2test: building server (example config, ReleaseFast) =="
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dconfig=config.example.conf)

echo "== h2test: starting server on :$PORT =="
"$BIN" --http --threads 2 --port "$PORT" >"$ROOT/bench/.cache/h2test-server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1
H2PORT="$PORT"

fail() { echo "h2test: FAIL: $1"; exit 1; }
ok() { echo "  ok: $1"; }

echo "== curl --http2-prior-knowledge checks =="
[ "$(curl -s -o /dev/null -w '%{http_code}' --http2-prior-knowledge "http://127.0.0.1:$H2PORT/")" = "200" ] || fail "GET / not 200"
ok "GET / -> 200"

python3 -c "print('h2'*512, end='')" > "$ROOT/bench/.cache/h2test-1k.txt"
curl -s --http2-prior-knowledge -X POST --data-binary @"$ROOT/bench/.cache/h2test-1k.txt" \
  "http://127.0.0.1:$H2PORT/echo" -o "$ROOT/bench/.cache/h2test-1k.resp"
cmp -s "$ROOT/bench/.cache/h2test-1k.txt" "$ROOT/bench/.cache/h2test-1k.resp" || fail "POST 1KB echo mismatch"
ok "POST /echo 1KB byte-exact"

python3 -c "import sys; sys.stdout.write('y'*204800)" > "$ROOT/bench/.cache/h2test-big.txt"
curl -s --http2-prior-knowledge -X POST --data-binary @"$ROOT/bench/.cache/h2test-big.txt" \
  "http://127.0.0.1:$H2PORT/echo" -o "$ROOT/bench/.cache/h2test-big.resp"
cmp -s "$ROOT/bench/.cache/h2test-big.txt" "$ROOT/bench/.cache/h2test-big.resp" || fail "POST 200KB echo mismatch"
ok "POST /echo 204800B byte-exact (flow control)"

[ "$(curl -s -o /dev/null -w '%{http_code}' -I --http2-prior-knowledge "http://127.0.0.1:$H2PORT/echo")" = "200" ] || fail "HEAD not 200"
ok "HEAD /echo -> 200"

[ "$(curl -s --http2-prior-knowledge "http://127.0.0.1:$H2PORT/static" | wc -c)" -gt 0 ] || fail "/static empty"
ok "GET /static serves content"

[ "$(curl -s -o /dev/null -w '%{http_code}' --http2-prior-knowledge "http://127.0.0.1:$H2PORT/old")" = "301" ] || fail "/old not 301"
ok "GET /old -> 301 redirect"

CONN=$(curl -s -v --http2-prior-knowledge \
  "http://127.0.0.1:$H2PORT/a" "http://127.0.0.1:$H2PORT/b" "http://127.0.0.1:$H2PORT/c" \
  "http://127.0.0.1:$H2PORT/d" "http://127.0.0.1:$H2PORT/e" "http://127.0.0.1:$H2PORT/f" \
  "http://127.0.0.1:$H2PORT/g" "http://127.0.0.1:$H2PORT/h" "http://127.0.0.1:$H2PORT/i" \
  "http://127.0.0.1:$H2PORT/j" 2>&1 | grep -c "Connected to")
[ "$CONN" = "1" ] || fail "expected 1 connection for 10 multiplexed requests, got $CONN"
ok "10 requests multiplexed on 1 connection"

# HTTP/1.1 must keep working on the same listener (no regression).
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$H2PORT/echo")" = "200" ] || fail "HTTP/1.1 regression"
ok "HTTP/1.1 still works on the same listener"

echo "== h2spec RFC-conformance suite =="
# h2spec exits non-zero when any test fails; capture its output regardless.
OUT=$("$H2SPEC" -p "$H2PORT" -h 127.0.0.1 2>&1 || true)
echo "$OUT" | grep -E "tests," || fail "no h2spec summary"
PASSED=$(echo "$OUT" | grep -oE "[0-9]+ tests, [0-9]+ passed, [0-9]+ skipped, [0-9]+ failed" | head -1)
echo "  $PASSED"
N=$(echo "$PASSED" | grep -oE "^[0-9]+")
P=$(echo "$PASSED" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+")
[ "$P" -ge "$MIN_PASS" ] || fail "h2spec passed $P < MIN_PASS=$MIN_PASS"
ok "h2spec $P/$N passed (>= $MIN_PASS)"

kill $SRV 2>/dev/null || true
wait $SRV 2>/dev/null || true
trap - EXIT
echo "== h2test: ALL PASS =="
