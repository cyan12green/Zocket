#!/usr/bin/env bash
# Instrumented end-to-end coverage: build the server WITH SanitizerCoverage
# (`-Dcoverage`, see `zig build cov`), drive broad traffic at it, SIGTERM
# (graceful stop returns from main) to flush each .zcov, and gather them for
# `zig-cov report`.
#
# Usage: bench/coverage-e2e.sh [workdir]
#   workdir defaults to bench/.cache/e2e-cov. Each scenario runs in a
#   subdir (one .zcov per server run). Needs zig-cov-rt.o resolvable via
#   -Dcoverage-rt (env COV_RT or ../zcov default) and python origins.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/bench/.cache/e2e-cov}"
COV_RT="${COV_RT:-/tmp/opencode/zcov/zig-out/lib/zig-cov-rt.o}"
PORT=18401

mkdir -p "$OUT"
cd "$ROOT"

build_cov() { # $1 = config path or "" for default, $2 = tag
    local cfg="${1:-}" tag="${2:-default}"
    echo "== e2e-cov: building [$tag] ${cfg:-default} =="
    if [ -n "$cfg" ]; then
        zig build -Dconfig="$cfg" -Dcoverage=true -Dcoverage-rt="$COV_RT" 2>&1 | tail -n 1
    else
        zig build -Dcoverage=true -Dcoverage-rt="$COV_RT" 2>&1 | tail -n 1
    fi
    cp zig-out/bin/zocket "$OUT/zocket-$tag"
}

run_traffic_default() { # default echo config on $PORT
    local dir="$OUT/default" bin="$OUT/zocket-default"
    mkdir -p "$dir" && cd "$dir"
    "$bin" --port "$PORT" --threads 2 >/dev/null 2>&1 &
    local srv=$!
    sleep 1
    python3 "$ROOT/bench/http-check.py" "$PORT" || true
    # error paths + methods + encodings in one pass
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "http://127.0.0.1:$PORT/" || true
    curl -s -X PUT --data-binary 'put-body' --max-time 3 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'PUT:%{http_code}\n' || true
    curl -s -X DELETE --max-time 3 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'DELETE:%{http_code}\n' || true
    curl -s -X OPTIONS --max-time 3 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'OPTIONS:%{http_code}\n' || true
    curl -s -X PATCH --data-binary 'p' --max-time 3 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'PATCH:%{http_code}\n' || true
    curl -s -H 'Accept-Encoding: gzip' --data-binary "$(python3 -c 'print("x "*2000, end="")')" --max-time 3 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'GZIP:%{http_code}\n' || true
    curl -s --http2-prior-knowledge --max-time 5 "http://127.0.0.1:$PORT/" -o /dev/null -w 'H2C:%{http_code}\n' || true
    curl -s --http2-prior-knowledge -X POST --data-binary 'h2data' --max-time 5 "http://127.0.0.1:$PORT/echo" -o /dev/null -w 'H2POST:%{http_code}\n' || true
    kill -TERM "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    cd "$ROOT"
}

run_traffic_full() { # 11-full.conf on $PORT (8080->override not possible; use --port? conf pins 8080; run as-is on 8080)
    # NOTE: the server runs with CWD=$ROOT: 11-full.conf uses repo-relative
    # paths (src/testdata/*, testdata/*). Its .zcov lands in $ROOT and is
    # moved into $dir afterwards (all *.zcov are gitignored anyway).
    local dir="$OUT/full" bin="$OUT/zocket-full"
    mkdir -p "$dir"
    # keepalive python origins for /cached (9000) and /auth (9100)
    python3 - "$ROOT" >origin.log 2>&1 <<'PYEOF' &
import sys
sys.path.insert(0, "/tmp/opencode")
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _r(self, body):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"v1"')
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self): self._r(b"origin:" + self.path.encode())
    def log_message(self, *a): pass
import threading
for port in (9000, 9100):
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever, daemon=True).start()
import time
time.sleep(3600)
PYEOF
    local orig=$!
    ls "$ROOT"/coverage-*.zcov 2>/dev/null | sort >"$dir"/.before
    cd "$ROOT"
    "$bin" --threads 2 >"$dir"/server.log 2>&1 &
    local srv=$!
    cd "$dir"
    sleep 1.5
    H="Host: app.example.com"
    get() { curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 -H "$H" "http://127.0.0.1:8080$1" || echo "000"; }
    echo "echo/health/status: $(get /echo) $(get /health) $(get /status)"
    echo "static/index/autoindex: $(get /static/hello.txt) $(get /static/) $(get /static/dir)"
    echo "range/cond: $(curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Range: bytes=0-4' http://127.0.0.1:8080/static/hello.txt || echo 000)"
    echo "precompressed: $(curl -s -D - -o /dev/null -H "$H" -H 'Accept-Encoding: gzip' http://127.0.0.1:8080/gz/hello.txt 2>/dev/null | grep -ci content-encoding || true)"
    echo "gzip-api: $(curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -H 'Accept-Encoding: gzip' --data-binary "$(python3 -c 'print("y "*3000, end="")')" http://127.0.0.1:8080/api || echo 000)"
    echo "proxy-dead: $(get /proxy)"
    echo "cached miss/hit: $(get /cached/data) $(curl -s -D - -o /dev/null -H "$H" http://127.0.0.1:8080/cached/data 2>/dev/null | grep -i '^X-Cache' || echo no-hdr)"
    echo "limited(25x): $(for i in $(seq 1 25); do get /limited; done | sort | uniq -c | tr '\n' ' ')"
    echo "admin 401/200: $(curl -s -o /dev/null -w '%{http_code}\n' -H "$H" http://127.0.0.1:8080/admin || echo 000) $(curl -s -o /dev/null -w '%{http_code}\n' -H "$H" -u alice:password http://127.0.0.1:8080/admin || echo 000)"
    echo "protected: $(get /protected)"
    echo "download: $(get /download/hello.txt)"
    echo "headers-demo: $(curl -s -D - -o /dev/null -H "$H" http://127.0.0.1:8080/headers-demo | grep -ciE 'x-extra|x-request-id' || true)hdrs"
    echo "regex: $(curl -s -H "$H" http://127.0.0.1:8080/users/42/ || echo 000)"
    echo "catchall-404: $(curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: nope.test' http://127.0.0.1:8080/ || echo 000)"
    echo "https-echo: $(curl -sk -X POST --data-binary 'tls' -w '%{http_code}\n' -H "$H" https://127.0.0.1:8080/echo || echo 000)"
    echo "h2c: $(curl -s -o /dev/null -w '%{http_code}\n' --http2-prior-knowledge -H "$H" http://127.0.0.1:8080/echo || echo 000)"
    kill -TERM "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    kill "$orig" 2>/dev/null || true
    comm -13 "$dir"/.before <(ls "$ROOT"/coverage-*.zcov 2>/dev/null | sort) | while read -r f; do mv "$f" "$dir"/; done
    rm -f "$dir"/.before
    cd "$ROOT"
}

build_cov "" default
run_traffic_default
build_cov examples/11-full.conf full
run_traffic_full

echo "== e2e-cov .zcov files =="
find "$OUT" -name "*.zcov" | head -n 20
