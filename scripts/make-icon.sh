#!/bin/bash
# Builds SpaceMap/AppIcon.icns from scripts/icon.swift (no committed binaries).
# Usage: scripts/make-icon.sh <output.icns>
set -euo pipefail

OUT="${1:?usage: make-icon.sh <output.icns>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift -O "$ROOT/scripts/icon.swift" "$WORK/master1024.png" >/dev/null
mkdir -p "$WORK/AppIcon.iconset"
sizes=(16 32 128 256 512)
for s in "${sizes[@]}"; do
    sips -z "$s" "$s" "$WORK/master1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    if [ "$d" -le 1024 ]; then
        sips -z "$d" "$d" "$WORK/master1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
printf 'Wrote %s\n' "$OUT"
