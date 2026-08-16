#!/usr/bin/env bash
# Build nginx with TLS + HTTP/2 (third_party/nginx @ release-1.28.0 with the
# echo-nginx-module), for the HTTPS benchmarks (M18). Same minimal module set
# as build-nginx.sh plus --with-http_ssl_module --with-http_v2_module.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/nginx-tls"
NGINX_SRC="$ROOT/third_party/nginx"
ECHO_MOD="$ROOT/third_party/echo-nginx-module"

if [ -x "$OUT/sbin/nginx" ]; then
    echo "nginx-tls already built at $OUT/sbin/nginx"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
cd "$NGINX_SRC"
./auto/configure \
    --prefix="$OUT" \
    --with-cc-opt="-O3" \
    --with-http_ssl_module \
    --with-http_v2_module \
    --without-http_rewrite_module \
    --without-http_gzip_module \
    --add-module="$ECHO_MOD" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
echo "nginx-tls built at $OUT/sbin/nginx"
