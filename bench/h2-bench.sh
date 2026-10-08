#!/usr/bin/env bash
# HTTP/2 over TLS benchmark: Zocket vs nginx, driven by h2load.
#
#   bench/h2-bench.sh [--reps N] [--duration S] [--conns "100 500"] [-m S]
#
# Cells are (connections x concurrent streams per connection) and both
# port layouts run interleaved to cancel port/co-residency bias. Results
# (median req/s, mean latency) are printed as a table and stored as
# h2load output under bench/results/h2/.
#
# Requires: h2load (third_party/nghttp2/build/src/h2load), a TLS-enabled
# nginx build (bench/build-nginx-tls.sh) and a P-256 cert pair at
# /tmp/opencode/bench-tls.{crt,key} (openssl req -x509 -newkey ec ...).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPS=3
DURATION=6
CONNS_LIST="100 500"
STREAMS=10

while [ $# -gt 0 ]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --conns) CONNS_LIST="$2"; shift 2 ;;
        -m) STREAMS="$2"; shift 2 ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

TCP_BIN="$ROOT/zig-out/bin/zocket"
H2LOAD="${H2LOAD:-$ROOT/third_party/nghttp2/build/src/h2load}"
NGINX_BIN="$ROOT/bench/.cache/nginx-tls/sbin/nginx"
NGINX_TEMPLATE="$ROOT/bench/foreign/nginx/h2-tls.conf.template"
CERT=/tmp/opencode/bench-tls.crt
KEY=/tmp/opencode/bench-tls.key
RES="$ROOT/bench/results/h2"
mkdir -p "$RES"

[ -x "$H2LOAD" ] || { echo "h2load missing: build third_party/nghttp2 (cmake --build build --target h2load)"; exit 1; }
[ -x "$NGINX_BIN" ] || bash "$ROOT/bench/build-nginx-tls.sh" >/dev/null
[ -f "$CERT" ] && [ -f "$KEY" ] || { echo "missing $CERT / $KEY"; exit 1; }

echo "== ensuring builds =="
(cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dconfig=bench/h2-tls-zocket.conf)

pkill_servers() {
    pkill -x zocket 2>/dev/null || true
    pkill -x nginx 2>/dev/null || true
    sleep 0.3
}
pkill_servers

start_servers() {
    local zport="$1" nport="$2"
    "$TCP_BIN" --port "$zport" --threads 4 >/dev/null 2>&1 &
    local prefix="$ROOT/bench/.cache/nginx-h2-$nport"
    mkdir -p "$prefix/logs" "$prefix"
    sed -e "s/@@PORT@@/$nport/" -e "s|@@ERRLOG@@|$prefix/logs/error.log|" \
        -e "s|@@PREFIX@@|$prefix|" -e "s|@@CERT@@|$CERT|" -e "s|@@KEY@@|$KEY|" \
        "$NGINX_TEMPLATE" > "$prefix/nginx.conf"
    "$NGINX_BIN" -c "$prefix/nginx.conf" -p "$prefix" >/dev/null 2>&1 &
    sleep 1.5
}

stop_servers() { pkill_servers; }

run_h2load() {
    local port="$1" conns="$2" out="$3"
    "$H2LOAD" -c "$conns" -m "$STREAMS" -t 4 -D "$DURATION" "https://127.0.0.1:$port/" \
        > "$out" 2>&1 || true
}

cell_stats() {
    # $1 = cell dir, $2 = server tag → median req/s + mean latency printed
    python3 - "$1" "$2" <<'EOF'
import glob, json, os, re, statistics, sys
d, tag = sys.argv[1], sys.argv[2]
rps, lat = [], []
for f in sorted(glob.glob(os.path.join(d, f"{tag}_*.txt"))):
    text = open(f, errors="replace").read()
    m = re.search(r"([\d.]+) req/s", text)
    if m:
        rps.append(float(m.group(1)))
    # "time for request:  <min>  <max>  <mean>  <sd>  <pct>" — mean is
    # the third value (units: us/ms/s).
    m = re.search(r"time for request:\s+\S+\s+\S+\s+([\d.]+)(us|ms|s)\b", text)
    if m:
        v = float(m.group(1))
        if m.group(2) == "ms":
            v *= 1000.0
        elif m.group(2) == "s":
            v *= 1_000_000.0
        lat.append(v)
print(f"{statistics.median(rps) if rps else 0:.0f} {statistics.mean(lat) if lat else 0:.0f}")
EOF
}

for conns in $CONNS_LIST; do
    label="c${conns}_m${STREAMS}"
    dir="$RES/$label"
    mkdir -p "$dir"
    # Fresh cell: stale samples from a shorter run must not mix in.
    rm -f "$dir"/*.txt
    echo "== cell $label (conns=$conns streams=$STREAMS) =="
    for rep in $(seq 1 "$REPS"); do
        if [ $((rep % 2)) -eq 1 ]; then zport=18443; nport=18444; tagA=zocket; tagB=nginx; p2=18444;
        else zport=18444; nport=18443; tagA=nginx; tagB=zocket; p2=18443; fi
        start_servers "$zport" "$nport"
        # Interleave within the rep: zocket, nginx, nginx, zocket.
        run_h2load "$zport" "$conns" "$dir/${tagA}_r${rep}a.txt"
        run_h2load "$nport" "$conns" "$dir/${tagB}_r${rep}a.txt"
        run_h2load "$nport" "$conns" "$dir/${tagB}_r${rep}b.txt"
        run_h2load "$zport" "$conns" "$dir/${tagA}_r${rep}b.txt"
        stop_servers
    done
    z=$(cell_stats "$dir" zocket); n=$(cell_stats "$dir" nginx)
    echo "  zocket: $z req/s (mean latency us)   nginx: $n req/s (mean latency us)"
    python3 - "$z" "$n" <<'EOF'
import sys
z = sys.argv[1].split(); n = sys.argv[2].split()
zr, nr = float(z[0]), float(n[0])
print(f"  -> zocket {zr:,.0f} vs nginx {nr:,.0f} req/s: ratio {zr/nr if nr else 0:.2f}x")
EOF
done
echo "done - raw h2load output in bench/results/h2/"
