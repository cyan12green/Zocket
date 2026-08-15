#!/usr/bin/env bash
# HTTP/2 benchmark: Zocket h2c vs nginx h2c (h2load, from third_party/nghttp2).
# Interleaved reps per workload; results land in bench/results/h2/ as one
# req/s per line, which bench/graphs.py renders into bench/graphs/h2_compare.png.
#
# Usage: bash bench/h2bench.sh   (needs the h2 binaries: zig-out/bin/zocket
# built with -Dconfig=config.example.json, and nginx-v2 + h2load per AGENTS.md).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H2LOAD="$ROOT/third_party/nghttp2/src/h2load"
NGINX="$ROOT/bench/.cache/nginx-v2/sbin/nginx"
CONF="$ROOT/bench/.cache/nginx-h2/nginx.conf"
ZPORT=18240
NPORT=18241
REPS=8
OUT="$ROOT/bench/results/h2"
mkdir -p "$OUT"

# nginx h2c config: pick a free port for this run.
sed -i "s/listen 127.0.0.1:[0-9]* http2;/listen 127.0.0.1:$NPORT http2;/" "$CONF"

[ -x "$H2LOAD" ] || { echo "h2bench: h2load missing (third_party/nghttp2, see AGENTS.md)"; exit 1; }
[ -x "$NGINX" ] || { echo "h2bench: nginx-v2 missing (bench/build-nginx-v2, see AGENTS.md)"; exit 1; }
"$ROOT/zig-out/bin/zocket" --http --threads 4 --port $ZPORT >"$OUT/zocket.log" 2>&1 &
ZS=$!
"$NGINX" -c "$CONF" >"$OUT/nginx.log" 2>&1 &
NS=$!
sleep 2

# $1=workload-label $2=port $3=path $4=m
run() {
  local label=$1 port=$2 path=$3 m=$4
  "$H2LOAD" -n 10000 -c 4 -m $m "http://127.0.0.1:$port$path" >/dev/null 2>&1  # warmup
  for i in $(seq 1 $REPS); do
    timeout 20 "$H2LOAD" -n 100000 -c 4 -m $m "http://127.0.0.1:$port$path" 2>&1 \
      | grep -aE "finished in" | grep -oE "[0-9.]+ req/s" | grep -oE "^[0-9.]+" >> "$OUT/${label}.txt"
  done
}

echo "== GET /echo, m=100 =="
run echo100_z $ZPORT /echo 100
run echo100_n $NPORT /echo 100
echo "== GET /echo, m=1 =="
run echo1_z $ZPORT /echo 1
run echo1_n $NPORT /echo 1
echo "== GET /static, m=100 =="
run static100_z $ZPORT /static 100
run static100_n $NPORT /static 100

kill $ZS $NS 2>/dev/null || true
pkill -x nginx 2>/dev/null
echo "results in $OUT (render with: python3 bench/graphs.py)"
