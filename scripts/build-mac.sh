#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  echo '需要在 macOS 13+ 上运行构建。' >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo '请先安装 Xcode Command Line Tools：xcode-select --install' >&2
  exit 1
fi
TASK_APP="$TASK_ROOT/build/TrailDrop.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
mkdir -p "$TASK_ROOT/build/module-cache"
bash "$TASK_ROOT/scripts/generate-icon.sh"
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/build/module-cache" xcrun swiftc -module-cache-path "$TASK_ROOT/build/module-cache" -parse-as-library -swift-version 5 -O \
  -target "$(uname -m)-apple-macosx13.0" \
  "$TASK_ROOT/Mac/TrailDropApp.swift" \
  -framework SwiftUI -framework AppKit -framework AVKit -framework QuickLookThumbnailing -framework DiskArbitration \
  -o "$TASK_APP/Contents/MacOS/TrailDrop"
if [ -f "$TASK_ROOT/build/runtime/traildrop-engine" ]; then
  cp "$TASK_ROOT/build/runtime/traildrop-engine" "$TASK_APP/Contents/Resources/traildrop-engine"
  chmod +x "$TASK_APP/Contents/Resources/traildrop-engine"
else
  cp "$TASK_ROOT/Core/engine.py" "$TASK_APP/Contents/Resources/engine.py"
fi
cp "$TASK_ROOT/Mac/Info.plist" "$TASK_APP/Contents/Info.plist"
cp "$TASK_ROOT/build/TrailDrop.icns" "$TASK_APP/Contents/Resources/TrailDrop.icns"
codesign --force --deep --sign - "$TASK_APP"
echo "已构建：$TASK_APP"
echo '开发测试包未公证，正式发布需要 Developer ID 签名与公证。'
if [ "${CI:-}" != true ]; then open "$TASK_APP"; fi
