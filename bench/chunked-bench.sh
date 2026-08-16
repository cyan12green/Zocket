#!/usr/bin/env bash
# HTTP/1.1 chunked-transfer benchmark: Zocket /chunked (route opt-in
# "chunked": true) vs nginx (echo-nginx-module with echo_flush, which
# forces chunked because the length is unknown at header time). POST echo:
# the request body is echoed back, framed as chunks. Interleaved reps;
# results land in bench/results/chunked/, rendered by bench/graphs.py into
# bench/graphs/chunked_compare.png.
#
# Usage: bash bench/chunked-bench.sh   (needs zig-out/bin/zocket built with
# -Dconfig=config.example.conf, nginx-v2 + echo-nginx-module, bombardier).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOMB="${BOMB:-$HOME/go/bin/bombardier}"
NGINX="$ROOT/bench/.cache/nginx-v2/sbin/nginx"
NGX_CONF="$ROOT/bench/nginx-chunked/nginx.conf"
ZPORT=18270
NPORT=18271
REPS=3
DUR=5s
OUT="$ROOT/bench/results/chunked"
mkdir -p "$OUT"

[ -x "$BOMB" ] || { echo "chunked-bench: bombardier missing (\$BOMB)"; exit 1; }
[ -x "$NGINX" ] || { echo "chunked-bench: nginx-v2 missing (bench/build-nginx-v2, see AGENTS.md)"; exit 1; }

sed -i "s/listen 127.0.0.1:[0-9]* http2;/listen 127.0.0.1:$NPORT http2;/" "$NGX_CONF"
"$ROOT/zig-out/bin/zocket" --http --threads 4 --port $ZPORT >"$OUT/zocket.log" 2>&1 &
ZS=$!
"$NGINX" -c "$NGX_CONF" >"$OUT/nginx.log" 2>&1 &
NS=$!
sleep 2

# $1=workload-label $2=port $3=path $4=body-bytes $5=conns
run() {
    local label=$1 port=$2 path=$3 body=$4 conns=$5
    local bs body_str
    bs=$(python3 -c "print('x' * $body)")
    for i in $(seq 1 $REPS); do
        "$BOMB" -m POST -b "$bs" -d $DUR -c $conns "http://127.0.0.1:$port$path" 2>/dev/null \
            | grep -aoE "Reqs/sec +[0-9.]+" | grep -oE "[0-9.]+" | head -1 >> "$OUT/${label}.txt"
    done
}

for body in 128 8192; do
  for conns in 10 100 1000; do
    echo "== POST echo body=${body}B conns=$conns =="
    run b${body}_c${conns}_z $ZPORT /chunked $body $conns
    run b${body}_c${conns}_n $NPORT /c $body $conns
  done
done

kill $ZS $NS 2>/dev/null || true
pkill -x nginx 2>/dev/null
echo "results in $OUT (render with: python3 bench/graphs.py)"
