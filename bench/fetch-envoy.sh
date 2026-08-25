#!/usr/bin/env bash
# Fetch the pinned Envoy release binary into bench/.cache/envoy/bin/envoy.
# Source is pinned as third_party/envoy (reference); binaries come from the
# official release archive since local Bazel builds are not practical.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.31.0"   # matches third_party/envoy release/v1.31 lineage pin target
OUT="$ROOT/bench/.cache/envoy/bin"
mkdir -p "$OUT"
[ -x "$OUT/envoy" ] && { echo "envoy already at $OUT/envoy"; exit 0; }
URL="https://github.com/envoyproxy/envoy/releases/download/v${VERSION}/envoy-${VERSION}-linux-x86_64"
curl -sL -o "$OUT/envoy" "$URL"
chmod +x "$OUT/envoy"
"$OUT/envoy" --version
echo "envoy fetched at $OUT/envoy"
