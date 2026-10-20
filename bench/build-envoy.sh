#!/usr/bin/env bash
# Fetch the pinned Envoy release used by the unified benchmark's Envoy cell
# (bench/foreign/envoy/unified.yaml.template). The binary lands in
# bench/.cache/envoy/envoy; bench/unified.sh picks it up through
# ENVOY_BIN, so the cell is reproducible instead of depending on a
# hand-installed binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/bench/.cache/envoy"
VERSION="${ENVOY_VERSION:-1.40.0}"
BIN="$OUT/envoy"

if [ -x "$BIN" ]; then
    echo "envoy already present at $BIN ($("$BIN" --version 2>&1 | head -1))"
    exit 0
fi

case "$(uname -m)" in
    x86_64) ARCH=x86_64 ;;
    aarch64) ARCH=aarch_64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

URL="https://github.com/envoyproxy/envoy/releases/download/v${VERSION}/envoy-${VERSION}-linux-${ARCH}"
mkdir -p "$OUT"
echo "fetching $URL"
curl -fsSL --retry 3 -o "$BIN" "$URL"
chmod +x "$BIN"
"$BIN" --version
echo "envoy ready at $BIN"
