#!/usr/bin/env bash
# Build Caddy (third_party/caddy @ v2.9.1) from source (Go toolchain).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/caddy/caddy"

if [ -x "$OUT" ]; then
    echo "caddy already built at $OUT"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
cd "$ROOT/third_party/caddy/cmd/caddy"
go build -o "$OUT" .
echo "caddy built at $OUT"
