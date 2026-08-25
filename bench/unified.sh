#!/usr/bin/env bash
# Unified benchmark harness — webserver, fileserver and load-balancer cells
# against nginx / HAProxy / Envoy / Zocket (see bench/UNIFIED.md).
#
#   bench/unified.sh [--quick] [--reps N]
#
# --quick: 1 rep per cell (smoke). Default: 3 reps + port-swap (=6 samples).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPS=3 DURATION=6s CONNS=100
QUICK=0
[ "${1:-}" = "--quick" ] && { QUICK=1; REPS=1; shift; }
[ "${1:-}" = "--reps" ] && { REPS="$2"; shift 2; }

TCP_BIN="$ROOT/zig-out/bin/zocket"
NGINX_BIN="$ROOT/bench/.cache/nginx-build/sbin/nginx"
HAPROXY_BIN="$ROOT/bench/.cache/haproxy-build/sbin/haproxy"
ENVOY_BIN="${ENVOY_BIN:-}"   # set ENVOY_BIN=/path/to/envoy to enable
BOMB=~/go/bin/bombardier
RES="$ROOT/bench/results/unified"
STATIC_DIR="$ROOT/bench/static"
AUTH_HEADER="Authorization: Basic YmVuY2g6cGFzc3dvcmQ="
ZP=18701 NP=18702 HP=18703 EP=18704 ORIGIN_BASE=18910

echo "== ensuring builds =="
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dconfig=bench/backlog-zocket.conf)
mkdir -p "$ROOT/bench/.cache"
if [ ! -x "$ROOT/bench/.cache/zocket-origin" ]; then
    (cd "$ROOT" && zig build -Doptimize=ReleaseFast)
    cp "$TCP_BIN" "$ROOT/bench/.cache/zocket-origin"
fi
ORIGIN_BIN="$ROOT/bench/.cache/zocket-origin"
[ -x "$NGINX_BIN" ] || bash "$ROOT/bench/build-nginx.sh" >/dev/null
HAVE_HAPROXY=0; [ -x "$HAPROXY_BIN" ] || { bash "$ROOT/bench/build-haproxy.sh" >/dev/null 2>&1 && HAVE_HAPROXY=1; } || HAVE_HAPROXY=$([ -x "$HAPROXY_BIN" ] && echo 1 || echo 0)
mkdir -p "$RES"

CELLS=(h1_echo static_small static_large precompressed cache_hit headers_ops auth_basic lb_rr)
PATHS=(/echo /f8k /f1m /f8k /cached /h /auth /proxied)

start_origins() {
    for i in 0 1 2 3; do
        "$ORIGIN_BIN" --http --port $((ORIGIN_BASE + i)) --threads 1 >/dev/null 2>&1 &
        OPIDS+=($!)
    done
}

start_zocket() { "$TCP_BIN" --port "$ZP" --threads 4 >/dev/null 2>&1 & ZPID=$!; }

start_nginx() {
    local prefix="$ROOT/bench/.cache/nginx-uni-p$NP"
    mkdir -p "$prefix"
    sed -e "s/@@PORT@@/$NP/" -e "s|@@ERRLOG@@|$ROOT/bench/.cache/nginx-uni.err|" \
        -e "s|@@PREFIX@@|$prefix|" -e "s|@@STATICDIR@@|$STATIC_DIR|" \
        "$ROOT/bench/foreign/nginx/nginx.conf.template" > "$ROOT/bench/.cache/nginx-uni.conf"
    "$NGINX_BIN" -p "$prefix" -c "$ROOT/bench/.cache/nginx-uni.conf" >/dev/null 2>&1 &
    NPIDS+=($!)
}

run_cell() { # cell port server rep path [extra hdr]
    local cell="$1" port="$2" srv="$3" rep="$4" path="$5"; shift 5
    mkdir -p "$RES/$cell"
    timeout $(( $(echo "$DURATION" | tr -dc 0-9) + 20 )) \
        "$BOMB" -c "$CONNS" -d "$DURATION" -l -o json "$@" \
        "http://127.0.0.1:$port$path" > "$RES/$cell/${srv}_r${rep}.json" 2>/dev/null || true
}

stop_all() {
    kill "${ZPID:-0}" 2>/dev/null || true
    for p in ${NPIDS[@]:-}; do kill "$p" 2>/dev/null || true; done
    for p in ${OPIDS[@]:-}; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap stop_all EXIT

for rep in $(seq 1 "$REPS"); do
    echo "== rep $rep/$REPS =="
    OPIDS=(); NPIDS=()
    start_origins; start_zocket; start_nginx
    sleep 1.5
    curl -s -o /dev/null "http://127.0.0.1:$ZP/cached" || true
    curl -s -o /dev/null "http://127.0.0.1:$NP/cached" || true
    for i in "${!CELLS[@]}"; do
        cell="${CELLS[$i]}"; path="${PATHS[$i]}"
        extra=()
        [ "$cell" = auth_basic ] && extra=(-H "$AUTH_HEADER")
        case "$path" in /echo) m=(-m POST -b "$(python3 -c "print('x'*1024)")");; *) m=();; esac
        run_cell "$cell" "$ZP" zocket "$rep" "$path" ${m[@]+"${m[@]}"} ${extra[@]+"${extra[@]}"}
        run_cell "$cell" "$NP" nginx "$rep" "$path" ${m[@]+"${m[@]}"} ${extra[@]+"${extra[@]}"}
    done
    stop_all
done

python3 bench/unified_summary.py
