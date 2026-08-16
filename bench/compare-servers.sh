#!/usr/bin/env bash
# Server-level comparison: Zocket vs actix-web (Rust) vs Bun.serve
# (JavaScript) vs httpx.zig, all built from third-party submodules.
#
# Single cell:
#   bench/compare-servers.sh [--workload get|post] [--conns N] [--reps N] [--duration s]
#
# Full matrix (POST body sizes x connections, full latency metrics):
#   bench/compare-servers.sh --matrix [--bodies "33 1024 8192 65536"]
#                             [--conns-list "10 100 1000"]
#                             [--reps N] [--duration s]
#
# Runs all four servers co-resident, interleaved bombardier reps, then swaps
# the port layout and repeats (port-bias correction), printing medians for
# both layouts and the combined table (rps, latency p50/p95/p99, throughput).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKLOAD=get
CONNS=500
REPS=6
DURATION=10s
BASE=18301
MATRIX=0
BODIES="33 1024 8192 65536"
CONNS_LIST="10 100 1000"

while [ $# -gt 0 ]; do
    case "$1" in
        --workload) WORKLOAD="$2"; shift 2 ;;
        --conns) CONNS="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --matrix) MATRIX=1; shift ;;
        --bodies) BODIES="$2"; shift 2 ;;
        --conns-list) CONNS_LIST="$2"; shift 2 ;;
        --static) STATIC_MODE=1; STATIC_SIZES="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

TCP_BIN="$ROOT/zig-out/bin/zocket"
ACTIX_BIN="$ROOT/bench/foreign/actix/target/release/actix_bench"
BUN_BIN="$ROOT/bench/.cache/bun/bun"
BUN_SRV="$ROOT/bench/foreign/bun/server.ts"
HX_BIN="$ROOT/third_party/httpx.zig/zig-out/bin/bench_server"
NGINX_BIN="$ROOT/bench/.cache/nginx-build/sbin/nginx"
NGINX_TEMPLATE="$ROOT/bench/foreign/nginx/nginx.conf.template"
CADDY_BIN="$ROOT/bench/.cache/caddy/caddy"
CADDY_TEMPLATE="$ROOT/bench/foreign/caddy/Caddyfile.template"

echo "== ensuring builds =="
[ -x "$TCP_BIN" ] || (cd "$ROOT" && zig build -Doptimize=ReleaseFast)
[ -x "$ACTIX_BIN" ] || (cd "$ROOT/bench/foreign/actix" && cargo build --release >/dev/null)
[ -x "$BUN_BIN" ] || bash "$ROOT/bench/fetch-bun.sh"
[ -x "$HX_BIN" ] || bash "$ROOT/bench/build-httpx.sh" >/dev/null
[ -x "$NGINX_BIN" ] || bash "$ROOT/bench/build-nginx.sh" >/dev/null
[ -x "$CADDY_BIN" ] || bash "$ROOT/bench/build-caddy.sh" >/dev/null

pkill_servers() {
    pkill -f "actix_benc[h]" 2>/dev/null || true
    pkill -f "bench_serve[r]" 2>/dev/null || true
    pkill -f "server\.t[s]" 2>/dev/null || true
    pkill -f "zocket_m14fu[l]l" 2>/dev/null || true
    pkill -f "caddy ru[n]" 2>/dev/null || true
    pkill -x zocket 2>/dev/null || true
    pkill -x nginx 2>/dev/null || true
    sleep 0.3
}
pkill_servers

# Static-file mode: every server serves the same generated file at
# GET /static (real disk path for tcp/nginx/caddy/actix/bun; preloaded
# into memory for httpx, which has no sendfile path).
STATIC_MODE=${STATIC_MODE:-0}
STATIC_SIZES=${STATIC_SIZES:-""}
STATIC_DIR="$ROOT/bench/.cache/static-1024"
STATIC_FILE="$STATIC_DIR/static"
STATIC_CONFIG="$ROOT/bench/.cache/static.conf"

gen_static_file() {
    # $1 = size in bytes. Deterministic xorshift64 fill so the bytes are
    # identical across runs (and incompressible-ish).
    local size="$1"
    STATIC_DIR="$ROOT/bench/.cache/static-$size"
    STATIC_FILE="$STATIC_DIR/static"
    mkdir -p "$STATIC_DIR"
    python3 -c "
import sys
seed = 0x9E3779B97F4A7C15
n = int(sys.argv[1])
out = bytearray()
while len(out) < n:
    seed ^= seed >> 12
    seed ^= (seed << 25) & 0xFFFFFFFFFFFFFFFF
    seed ^= seed >> 27
    out += (seed & 0xFFFF).to_bytes(2, 'big')
open(sys.argv[2], 'wb').write(out[:n])
" "$size" "$STATIC_FILE"
    # Zocket config: prefix route "/" rooted at the static dir; the
    # static module resolves /static -> $DIR/static (sendfile >= 16 KB).
    # Conf files are comptime-only: write a .conf and rebuild with it
    # (path project-root-relative for the @embedFile reach).
    cat > "$STATIC_CONFIG" <<CONF
server {
    location / {
        content static;
        root $STATIC_DIR;
    }
}
CONF
    (cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dconfig="${STATIC_CONFIG#"$ROOT"/}")
}

start_servers() {
    # $1 = tcp port, $2 = actix port, $3 = bun port, $4 = httpx port,
    # $5 = nginx port, $6 = caddy port
    if [ "$STATIC_MODE" = "1" ]; then
        "$TCP_BIN" --http --port "$1" --threads 4 >/dev/null 2>&1 &
        ACTIX_STATIC="$STATIC_FILE" "$ACTIX_BIN" "$2" 4 >/dev/null 2>&1 &
        BUN_STATIC="$STATIC_FILE" "$BUN_BIN" run "$BUN_SRV" "$3" >/dev/null 2>&1 &
        "$HX_BIN" --port "$4" --static "$STATIC_FILE" >/dev/null 2>&1 &
    else
        "$TCP_BIN" --port "$1" --threads 4 >/dev/null 2>&1 &
        "$ACTIX_BIN" "$2" 4 >/dev/null 2>&1 &
        "$BUN_BIN" run "$BUN_SRV" "$3" >/dev/null 2>&1 &
        "$HX_BIN" --port "$4" >/dev/null 2>&1 &
    fi
    # nginx: per-port runtime prefix (pid file) and config.
    NGINX_PREFIX="$ROOT/bench/.cache/nginx-p$5"
    mkdir -p "$NGINX_PREFIX"
    sed -e "s/@@PORT@@/$5/" \
        -e "s|@@ERRLOG@@|$ROOT/bench/.cache/nginx-err-$5.log|" \
        -e "s|@@PREFIX@@|$NGINX_PREFIX|" \
        -e "s|@@STATICDIR@@|$STATIC_DIR|" "$NGINX_TEMPLATE" > "$ROOT/bench/.cache/nginx-$5.conf"
    "$NGINX_BIN" -p "$NGINX_PREFIX" -c "$ROOT/bench/.cache/nginx-$5.conf" >/dev/null 2>&1 &
    # caddy: GOMAXPROCS=4 for parity with the other 4-worker servers.
    sed -e "s/@@PORT@@/$6/" \
        -e "s|@@STATICDIR@@|$STATIC_DIR|" "$CADDY_TEMPLATE" > "$ROOT/bench/.cache/caddy-$6.caddyfile"
    GOMAXPROCS=4 "$CADDY_BIN" run --config "$ROOT/bench/.cache/caddy-$6.caddyfile" --adapter caddyfile >/dev/null 2>&1 &
    sleep 2
}

stop_servers() { pkill_servers; }

# run_cell: sweep one (body, conns) cell in both port layouts.
# $1 = cell label (e.g. "b33_c100"), $2 = conns, $3 = body size (0 = GET / empty)
run_cell() {
    local label="$1" conns="$2" body="$3"
    local resdir="$RESROOT/$label"
    mkdir -p "$resdir"
    echo "== cell $label (conns=$conns body=$body) =="

    local bombbase=(-c "$conns" -d "$DURATION" -l -o json)
    local args
    if [ "$STATIC_MODE" = "1" ]; then
        args=("${bombbase[@]}")
    elif [ "$body" = "0" ]; then
        args=("${bombbase[@]}")
    else
        args=("${bombbase[@]}" -m POST -b "$(python3 -c "print('x' * $body)")")
    fi

    run_layout() {
        # $1 = label prefix, $2..$7 = ports
        local pref="$1" tcp_port=$2 actix_port=$3 bun_port=$4 hx_port=$5 nginx_port=$6 caddy_port=$7
        start_servers "$tcp_port" "$actix_port" "$bun_port" "$hx_port" "$nginx_port" "$caddy_port"

        for srv in "$tcp_port" "$actix_port" "$bun_port" "$hx_port" "$nginx_port" "$caddy_port"; do
            path="/"
            if [ "$STATIC_MODE" = "1" ]; then
                path="/static"
            elif [ "$body" != "0" ]; then
                path="/echo"
            fi
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${srv}${path}" || echo 000)
            echo "  health :${srv}${path} -> ${code}"
        done

        for r in $(seq 1 "$REPS"); do
            for srv in tcp actix bun hx nginx caddy; do
                case "$srv" in
                    tcp) port="$tcp_port" ;;
                    actix) port="$actix_port" ;;
                    bun) port="$bun_port" ;;
                    hx) port="$hx_port" ;;
                    nginx) port="$nginx_port" ;;
                    caddy) port="$caddy_port" ;;
                esac
                path="/"
                if [ "$STATIC_MODE" = "1" ]; then
                    path="/static"
                elif [ "$body" != "0" ]; then
                    path="/echo"
                fi
                ~/go/bin/bombardier "${args[@]}" "http://127.0.0.1:${port}${path}" > "$resdir/${pref}_${srv}_r${r}.json" 2>/dev/null
            done
        done
        stop_servers
    }

    run_layout A "$BASE" "$((BASE+1))" "$((BASE+2))" "$((BASE+3))" "$((BASE+4))" "$((BASE+5))"
    run_layout B "$((BASE+5))" "$((BASE+4))" "$((BASE+3))" "$((BASE+2))" "$((BASE+1))" "$BASE"
}

trap 'stop_servers' EXIT

if [ "$MATRIX" = "1" ]; then
    RESROOT="$ROOT/bench/results/servers/matrix"
    rm -rf "$RESROOT"
    mkdir -p "$RESROOT"
    CELLS="GET_(empty)|get_c0"
    run_cell "get_c0" "100" "0"
    for body in $BODIES; do
        for conns in $CONNS_LIST; do
            CELLS="$CELLS POST_/echo_body=${body}B_conns=${conns}|b${body}_c${conns}"
            run_cell "b${body}_c${conns}" "$conns" "$body"
        done
    done
elif [ "$STATIC_MODE" = "1" ]; then
    RESROOT="$ROOT/bench/results/servers/static"
    rm -rf "$RESROOT"
    mkdir -p "$RESROOT"
    CELLS=""
    for size in $STATIC_SIZES; do
        gen_static_file "$size"
        for conns in $CONNS_LIST; do
            CELLS="$CELLS static_${size}B_conns=${conns}|s${size}_c${conns}"
            run_cell "s${size}_c${conns}" "$conns" "0"
        done
    done
else
    RESROOT="$ROOT/bench/results/servers/${WORKLOAD}_c${CONNS}"
    mkdir -p "$RESROOT"
    body=0
    [ "$WORKLOAD" = "post" ] && body=33
    CELLS=""
    run_cell "cell" "$CONNS" "$body"
fi

python3 - "$RESROOT" "$MATRIX" "$CELLS" <<'EOF'
import json, glob, os, statistics, sys

root = sys.argv[1]
matrix = sys.argv[2] == "1"
cells = sys.argv[3].split()

servers = [("tcp", "Zocket"), ("actix", "actix-web"), ("bun", "Bun.serve"), ("hx", "httpx.zig"), ("nginx", "nginx"), ("caddy", "Caddy")]

def stats(d, name):
    vals = {"rps": [], "p50": [], "p95": [], "p99": [], "tput": []}
    for f in sorted(glob.glob(os.path.join(d, f"{name}_r*.json"))):
        try:
            text = open(f).read()
            j = json.loads(text[text.find("{"):])
            r = j["result"]
            vals["rps"].append(r["rps"]["mean"])
            vals["p50"].append(r["latency"]["percentiles"]["50"])
            vals["p95"].append(r["latency"]["percentiles"]["95"])
            vals["p99"].append(r["latency"]["percentiles"]["99"])
            vals["tput"].append(r["bytesRead"] / r["timeTakenSeconds"])
        except Exception:
            pass
    out = {}
    for k, v in vals.items():
        out[k] = statistics.median(v) if v else 0.0
    return out

def us(us):
    return f"{us/1000.0:.3f} ms"

def mbs(bps):
    return f"{bps/1e6:.1f} MB/s"

# Cell labels arrive via argv: for each a "label|relative-dir" entry.
print(f"\n== comparison matrix (medians of reps, both port layouts combined) ==")
for entry in cells:
    label, rel = entry.split("|")
    d = os.path.join(root, rel)
    print(f"\n### {label}")
    print("| server | reqs/sec | vs Zocket | latency p50 | latency p95 | latency p99 | throughput |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    tcp = None
    for tag, name in servers:
        if not any(os.path.exists(os.path.join(d, f"{p}_{tag}_r1.json")) for p in ("A", "B")):
            continue
        a = stats(d, f"A_{tag}")
        c = stats(d, f"B_{tag}")
        rps = statistics.median([a["rps"], c["rps"]])
        p50 = statistics.median([a["p50"], c["p50"]])
        p95 = statistics.median([a["p95"], c["p95"]])
        p99 = statistics.median([a["p99"], c["p99"]])
        tput = statistics.median([a["tput"], c["tput"]])
        if tag == "tcp":
            tcp = rps
            rel = "1.00x"
        else:
            rel = f"{rps/tcp:.2f}x" if tcp else "-"
        print(f"| {name} | {rps:,.0f} | {rel} | {us(p50)} | {us(p95)} | {us(p99)} | {mbs(tput)} |")
EOF
