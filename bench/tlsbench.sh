#!/usr/bin/env bash
# HTTP/2 over TLS benchmark (M18): Zocket TLS vs nginx TLS (h2load with
# ALPN h2). Interleaved reps per workload; results land in bench/results/tls/
# as one req/s per line (rendered by bench/graphs.py).
#
# Usage: bash bench/tlsbench.sh   (needs zig-out/bin/zocket with the TLS
# config, nginx-tls + h2load per AGENTS.md; certs in src/testdata/tls/).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H2LOAD="$ROOT/third_party/nghttp2/src/h2load"
NGINX="$ROOT/bench/.cache/nginx-tls/sbin/nginx"
NCONF="$ROOT/bench/.cache/nginx-tls.conf"
ZCONF="/tmp/opencode/tls-bench-config.json"
ZPORT=18441
NPORT=18402
REPS=8
OUT="$ROOT/bench/results/tls"
mkdir -p "$OUT"

[ -x "$H2LOAD" ] || { echo "tlsbench: h2load missing (third_party/nghttp2, see AGENTS.md)"; exit 1; }
[ -x "$NGINX" ] || { echo "tlsbench: nginx-tls missing (build with --with-http_ssl_module --with-http_v2_module)"; exit 1; }

"$ROOT/zig-out/bin/zocket" --http --threads 4 --port $ZPORT --config "$ZCONF" >"$OUT/zocket.log" 2>&1 &
ZS=$!
"$NGINX" -c "$NCONF" >"$OUT/nginx.log" 2>&1 &
NS=$!
sleep 2

# $1=workload-label $2=port $3=path $4=m
run() {
  local label=$1 port=$2 path=$3 m=$4
  "$H2LOAD" -n 10000 -c 4 -m $m --alpn-list=h2 "https://127.0.0.1:$port$path" >/dev/null 2>&1  # warmup
  for i in $(seq 1 $REPS); do
    timeout 20 "$H2LOAD" -n 100000 -c 4 -m $m --alpn-list=h2 "https://127.0.0.1:$port$path" 2>&1 \
      | grep -aE "finished in" | grep -oE "[0-9.]+ req/s" | grep -oE "^[0-9.]+" >> "$OUT/${label}.txt"
  done
}

echo "== GET / (empty), m=100 =="
run empty100_z $ZPORT / 100
run empty100_n $NPORT / 100
echo "== GET /echo, m=100 =="
run echo100_z $ZPORT /echo 100
run echo100_n $NPORT /echo 100
echo "== GET /echo, m=1 =="
run echo1_z $ZPORT /echo 1
run echo1_n $NPORT /echo 1
echo "== GET /static (1 KB), m=100 =="
run static100_z $ZPORT /static 100
run static100_n $NPORT /static 100

kill $ZS $NS 2>/dev/null || true
pkill -x nginx 2>/dev/null
echo "results in $OUT (render with: python3 bench/graphs.py)"
