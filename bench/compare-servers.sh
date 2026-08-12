#!/usr/bin/env bash
# Server-level comparison: tcp-server vs actix-web (Rust) vs Bun.serve
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
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

TCP_BIN="$ROOT/zig-out/bin/tcp_server"
ACTIX_BIN="$ROOT/bench/foreign/actix/target/release/actix_bench"
BUN_BIN="$ROOT/bench/.cache/bun/bun"
BUN_SRV="$ROOT/bench/foreign/bun/server.ts"
HX_BIN="$ROOT/third_party/httpx.zig/zig-out/bin/bench_server"

echo "== ensuring builds =="
[ -x "$TCP_BIN" ] || (cd "$ROOT" && zig build -Doptimize=ReleaseFast)
[ -x "$ACTIX_BIN" ] || (cd "$ROOT/bench/foreign/actix" && cargo build --release >/dev/null)
[ -x "$BUN_BIN" ] || bash "$ROOT/bench/fetch-bun.sh"
[ -x "$HX_BIN" ] || bash "$ROOT/bench/build-httpx.sh" >/dev/null

pkill_servers() {
    pkill -f "actix_benc[h]" 2>/dev/null || true
    pkill -f "bench_serve[r]" 2>/dev/null || true
    pkill -f "server\.t[s]" 2>/dev/null || true
    pkill -f "tcp_server_m14fu[l]l" 2>/dev/null || true
    pkill -x tcp_server 2>/dev/null || true
    sleep 0.3
}
pkill_servers

start_servers() {
    # $1 = tcp port, $2 = actix port, $3 = bun port, $4 = httpx port
    "$TCP_BIN" --port "$1" --threads 4 >/dev/null 2>&1 &
    "$ACTIX_BIN" "$2" 4 >/dev/null 2>&1 &
    "$BUN_BIN" run "$BUN_SRV" "$3" >/dev/null 2>&1 &
    "$HX_BIN" --port "$4" >/dev/null 2>&1 &
    sleep 1.5
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
    if [ "$body" = "0" ]; then
        args=("${bombbase[@]}")
    else
        args=("${bombbase[@]}" -m POST -b "$(python3 -c "print('x' * $body)")")
    fi

    run_layout() {
        # $1 = label prefix, $2..$5 = ports
        local pref="$1" tcp_port=$2 actix_port=$3 bun_port=$4 hx_port=$5
        start_servers "$tcp_port" "$actix_port" "$bun_port" "$hx_port"

        for srv in "$tcp_port" "$actix_port" "$bun_port" "$hx_port"; do
            path="/"
            [ "$body" != "0" ] && path="/echo"
            code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${srv}${path}" || echo 000)
            echo "  health :${srv}${path} -> ${code}"
        done

        for r in $(seq 1 "$REPS"); do
            for srv in tcp actix bun hx; do
                case "$srv" in
                    tcp) port="$tcp_port" ;;
                    actix) port="$actix_port" ;;
                    bun) port="$bun_port" ;;
                    hx) port="$hx_port" ;;
                esac
                path="/"
                [ "$body" != "0" ] && path="/echo"
                ~/go/bin/bombardier "${args[@]}" "http://127.0.0.1:${port}${path}" > "$resdir/${pref}_${srv}_r${r}.json" 2>/dev/null
            done
        done
        stop_servers
    }

    run_layout A "$BASE" "$((BASE+1))" "$((BASE+2))" "$((BASE+3))"
    run_layout B "$((BASE+3))" "$((BASE+2))" "$((BASE+1))" "$BASE"
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

servers = [("tcp", "tcp-server"), ("actix", "actix-web"), ("bun", "Bun.serve"), ("hx", "httpx.zig")]

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
    print("| server | reqs/sec | vs tcp-server | latency p50 | latency p95 | latency p99 | throughput |")
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
