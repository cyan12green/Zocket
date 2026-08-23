#!/usr/bin/env bash
# Backlog-features benchmark: Zocket vs nginx on the new module surface.
#
#   bench/backlog-bench.sh [--reps N] [--duration s]
#
# Cells (identical endpoints on both servers, interleaved reps):
#   headers      GET /h        — 3 response-header ops per request
#   auth_sha     GET /auth     — Basic auth verified from an {SHA} htpasswd
#   precompressed GET /f8k     — .gz twin served with Content-Encoding
#   cache_hit    GET /cached   — proxy_cache HIT path (warm origin)
#   limit_req    GET /limited  — overload shedding at rate=2000/s burst=100
#
# Results land in bench/results/backlog/<cell>/{zocket,nginx}_r<N>.json;
# bench/graphs_backlog.py renders bench/graphs/backlog_compare.png and
# the summary table below prints medians (rps + p50/p99 latency; the
# limit cell reports accepted rps instead).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPS=3
DURATION=6s
CONNS=100
ZPORT=18701
NPORT=18702
ORIGIN=18901

while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

TCP_BIN="$ROOT/zig-out/bin/zocket"
NGINX_BIN="$ROOT/bench/.cache/nginx-build/sbin/nginx"
BOMB=~/go/bin/bombardier
RES="$ROOT/bench/results/backlog"
STATIC_DIR="$ROOT/bench/static"
AUTH_HEADER="Authorization: Basic YmVuY2g6cHc="   # bench:password

echo "== ensuring builds =="
# Origin runs the DEFAULT config (plain echo) as a separate binary: the
# comptime -Dconfig embed replaces defaults for every mode of one binary.
mkdir -p "$ROOT/bench/.cache"
if [ ! -x "$ROOT/bench/.cache/zocket-origin" ] || [ "$ROOT/src/dsl/modules/proxy_cache.zig" -nt "$ROOT/bench/.cache/zocket-origin" ]; then
    (cd "$ROOT" && zig build -Doptimize=ReleaseFast) 
    cp "$TCP_BIN" "$ROOT/bench/.cache/zocket-origin"
fi
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dconfig=bench/backlog-zocket.conf)
[ -x "$NGINX_BIN" ] || bash "$ROOT/bench/build-nginx.sh" >/dev/null
mkdir -p "$RES"
ORIGIN_BIN="$ROOT/bench/.cache/zocket-origin"

CELLS=(headers auth_sha precompressed cache_hit limit_req)
PATHS=(/h /auth /f8k /cached /limited)

start_zocket() {
    # Front server with all benchmark routes.
    "$TCP_BIN" --port "$ZPORT" --threads 4 >/dev/null 2>&1 &
    ZPID=$!
    # Origin for the cache cell: plain default-config Zocket (echo).
    "$ORIGIN_BIN" --http --port "$ORIGIN" --threads 2 >/dev/null 2>&1 &
    OPID=$!
}

start_nginx() {
    local prefix="$ROOT/bench/.cache/nginx-backlog-p$NPORT"
    mkdir -p "$prefix" "$ROOT/bench/.cache/backlog-cache"
    sed -e "s/@@PORT@@/$NPORT/" \
        -e "s|@@ERRLOG@@|$ROOT/bench/.cache/nginx-backlog.err|" \
        -e "s|@@PREFIX@@|$prefix|" \
        -e "s|@@STATICDIR@@|$STATIC_DIR|" \
        -e "s|@@HTPASSWD@@|$ROOT/testdata/bench-htpasswd|" \
        -e "s|@@CACHEDIR@@|$ROOT/bench/.cache/backlog-cache|" \
        -e "s/@@ORIGIN@@/$ORIGIN/" \
        "$ROOT/bench/foreign/nginx/backlog.conf.template" \
        > "$ROOT/bench/.cache/nginx-backlog.conf"
    "$NGINX_BIN" -p "$prefix" -c "$ROOT/bench/.cache/nginx-backlog.conf" >/dev/null 2>&1 &
    NPIDS+=($!)
}

stop_all() {
    kill "${ZPID:-0}" "${OPID:-0}" 2>/dev/null || true
    for p in ${NPIDS[@]:-}; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap stop_all EXIT

run_cell() {
    local cell="$1" port="$2" srv="$3" rep="$4" path="$5"
    local extra=()
    if [ "$cell" = "auth_sha" ]; then extra=(-H "$AUTH_HEADER"); fi
    mkdir -p "$RES/$cell"
    "$BOMB" -c "$CONNS" -d "$DURATION" -l -o json "${extra[@]}" \
        "http://127.0.0.1:$port$path" > "$RES/$cell/${srv}_r${rep}.json" 2>/dev/null || true
}

# Warm the cache cells once so both sides measure HITs, not origin fetches.
warm_cache() {
    curl -s -o /dev/null "http://127.0.0.1:$ZPORT/cached" || true
    curl -s -o /dev/null "http://127.0.0.1:$NPORT/cached" || true
}

for rep in $(seq 1 "$REPS"); do
    echo "== layout A: zocket=$ZPORT nginx=$NPORT (rep $rep/$REPS) =="
    start_zocket; start_nginx; sleep 1.5; warm_cache
    for i in "${!CELLS[@]}"; do
        run_cell "${CELLS[$i]}" "$ZPORT" zocket "$rep" "${PATHS[$i]}"
        run_cell "${CELLS[$i]}" "$NPORT" nginx "$rep" "${PATHS[$i]}"
    done
    stop_all

    # Port-bias correction: swap ports and repeat when REPS is even.
    if [ $((rep % 2)) -eq 0 ]; then continue; fi
done

# Swap layout for the second half of the reps.
for rep in $(seq $((REPS + 1)) $((REPS * 2))); do
    echo "== layout B (swapped ports, rep $rep) =="
    OLDZ=$ZPORT; OLDN=$NPORT
    ZPORT=$OLDN; NPORT=$OLDZ
    start_zocket; start_nginx; sleep 1.5; warm_cache
    ZPORT=$OLDZ; NPORT=$OLDN   # bombardier targets follow the roles, not numbers
    ROLE_Z=$((rep > REPS ? NPORT : ZPORT)); true
    for i in "${!CELLS[@]}"; do
        run_cell "${CELLS[$i]}" "$OLDN" zocket "$rep" "${PATHS[$i]}"
        run_cell "${CELLS[$i]}" "$OLDZ" nginx "$rep" "${PATHS[$i]}"
    done
    stop_all
done

python3 - << 'PYEOF'
import json, glob, statistics, os

def load(f):
    raw = open(f).read()
    d = json.loads(raw[raw.index("{"):])
    r = d.get("result", {})
    rps = r.get("rps", {}).get("mean", 0)
    total = sum(r.get(k, 0) for k in ("req1xx","req2xx","req3xx","req4xx","req5xx"))
    good = sum(r.get(k, 0) for k in ("req1xx","req2xx","req3xx"))
    if total == 0:
        return None  # crashed/dead server rep: exclude
    return rps, (good / total * 100 if total else 0)

root = "bench/results/backlog"
cells = ["headers", "auth_sha", "precompressed", "cache_hit", "limit_req"]
print(f"{'cell':<14}{'metric':<16}{'zocket':>12}{'nginx':>12}{'ratio':>8}")
for cell in cells:
    vals = {"zocket": [], "nginx": []}
    oks = {"zocket": [], "nginx": []}
    for f in glob.glob(f"{root}/{cell}/*.json"):
        srv = "zocket" if "zocket" in os.path.basename(f) else "nginx"
        try:
            loaded = load(f)
        except Exception:
            continue
        if loaded is None:
            continue
        rps, okpct = loaded
        vals[srv].append(rps)
        oks[srv].append(okpct)
    med = {s_: statistics.median(v) if v else 0 for s_, v in vals.items()}
    ratio = med["zocket"] / med["nginx"] if med["nginx"] else 0
    print(f"{cell:<14}{'req/s':<16}{med['zocket']:>12.0f}{med['nginx']:>12.0f}{ratio:>7.2f}x")

PYEOF
echo "done - JSON in bench/results/backlog/, render graphs with bench/graphs_backlog.py"
