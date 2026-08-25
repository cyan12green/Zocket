#!/usr/bin/env bash
# Build HAProxy into bench/.cache/haproxy-build/sbin/haproxy (pinned 3.2.x).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/haproxy-build"
VER="3.2.4"
mkdir -p "$ROOT/bench/.cache" "$OUT"
cd "$ROOT/bench/.cache"
[ -d haproxy-$VER ] || {
    curl -sL "https://www.haproxy.org/download/$VER/src/haproxy-$VER.tar.gz" | tar xz
}
cd haproxy-$VER
make -j"$(nproc)" TARGET=linux-glibc USE_OPENSSL=1 USE_ZLIB=1 USE_PCRE2=1 >/dev/null
cp haproxy "$OUT/sbin/haproxy"
echo "haproxy built at $OUT/sbin/haproxy"
