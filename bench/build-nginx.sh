#!/usr/bin/env bash
# Build nginx (third_party/nginx @ release-1.28.0) with the echo-nginx-module
# (third_party/echo-nginx-module @ v0.65), minimal module set for benchmark
# parity (no rewrite/gzip/ssl; access log off in the config).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/nginx-build"
NGINX_SRC="$ROOT/third_party/nginx"
ECHO_MOD="$ROOT/third_party/echo-nginx-module"

if [ -x "$OUT/sbin/nginx" ]; then
    echo "nginx already built at $OUT/sbin/nginx"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
cd "$NGINX_SRC"
# nginx's configure lives in auto/ in the GitHub mirror (1.28+ layout).
./auto/configure \
    --prefix="$OUT" \
    --with-cc-opt="-O3" \
    --without-http_rewrite_module \
    --without-http_gzip_module \
    --with-http_gzip_static_module \
    --add-module="$ECHO_MOD" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
echo "nginx built at $OUT/sbin/nginx"
