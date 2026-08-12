#!/usr/bin/env bash
# Fetch the Bun runtime binary pinned by the third_party/bun submodule
# (tag bun-v1.3.14). The binary is a GitHub release asset, not part of the
# git repo; it is cached in bench/.cache/bun/ (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUN_VERSION=1.3.14
CACHE="$ROOT/bench/.cache/bun"
BIN="$CACHE/bun"

if [ -x "$BIN" ]; then
    echo "bun present: $("$BIN" --version)"
    exit 0
fi

echo "fetching bun v${BUN_VERSION}..."
mkdir -p "$CACHE"
curl -sL -o "$CACHE/bun.zip" \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip"
unzip -o -q "$CACHE/bun.zip" -d "$CACHE"
chmod +x "$CACHE/bun-linux-x64/bun"
mv "$CACHE/bun-linux-x64/bun" "$BIN"
rm -f "$CACHE/bun.zip"
rm -rf "$CACHE/bun-linux-x64"
echo "bun ready: $("$BIN" --version)"
