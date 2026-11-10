#!/bin/bash
# Regenerate the NormalSwitcher app icons and README preview on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swift -module-cache-path "$TEMP/swift-cache" "$ROOT/macos/make_icon.swift" "$ROOT"
