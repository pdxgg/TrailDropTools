#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ICONSET="$TASK_ROOT/build/TrailDrop.iconset"
TASK_PNG="$TASK_ROOT/build/TrailDrop-1024.png"
mkdir -p "$TASK_ROOT/build/module-cache" "$TASK_ICONSET"
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/module-cache" \
  xcrun swift -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT/scripts/render-icon.swift" "$TASK_ROOT/assets/traildrop-icon.svg" "$TASK_PNG"
for TASK_SIZE in 16 32 128 256 512; do
  sips -z "$TASK_SIZE" "$TASK_SIZE" "$TASK_PNG" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
  TASK_DOUBLE=$((TASK_SIZE * 2))
  sips -z "$TASK_DOUBLE" "$TASK_DOUBLE" "$TASK_PNG" --out "$TASK_ICONSET/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
python3 "$TASK_ROOT/scripts/png-to-icns.py" "$TASK_ICONSET" "$TASK_ROOT/build/TrailDrop.icns"
echo "已生成图标：$TASK_ROOT/build/TrailDrop.icns"
