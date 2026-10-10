#!/usr/bin/env bash
# Build HAProxy into bench/.cache/haproxy-build/sbin/haproxy (pinned 3.2.x).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/haproxy-build"
VER="3.0.9"
mkdir -p "$ROOT/bench/.cache" "$OUT/sbin"
cd "$ROOT/bench/.cache"
[ -d haproxy-$VER ] || {
    curl -sL -o haproxy.tgz "https://www.haproxy.org/download/$VER/src/haproxy-$VER.tar.gz" &&
        tar xzf haproxy.tgz
}
cd haproxy-$VER
# PCRE2 is optional for the benchmark routes; use it when the dev headers
# are present and fall back to the built-in matcher otherwise.
if [ -f /usr/include/pcre2.h ] || pkg-config --exists libpcre2-8 2>/dev/null; then
    PCRE=USE_PCRE2=1
else
    PCRE=USE_PCRE2=
fi
make -j"$(nproc)" TARGET=linux-glibc USE_OPENSSL=1 USE_ZLIB=1 "$PCRE" >/dev/null
cp haproxy "$OUT/sbin/haproxy"
echo "haproxy built at $OUT/sbin/haproxy"
