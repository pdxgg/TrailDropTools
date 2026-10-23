#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ARCH="${TASK_ARCH:-$(uname -m)}"
TASK_STAGE="$TASK_ROOT/build/dmg-stage-$TASK_ARCH"
TASK_DMG="$TASK_ROOT/build/TrailDrop-0.1.3-$TASK_ARCH.dmg"
if [ ! -x "$TASK_ROOT/build/TrailDrop.app/Contents/Resources/traildrop-engine" ]; then
  echo '缺少内嵌文件引擎；请先打包运行时并重新构建 App。' >&2
  exit 1
fi
mkdir -p "$TASK_STAGE"
ditto "$TASK_ROOT/build/TrailDrop.app" "$TASK_STAGE/TrailDrop.app"
rm -f "$TASK_STAGE/Applications"
ln -s /Applications "$TASK_STAGE/Applications"
cat > "$TASK_STAGE/安装说明.txt" <<'INSTALL'
轻舟 TrailDrop 0.1.3

将 TrailDrop.app 拖到 Applications 文件夹后打开。
已内嵌运行时，不需要安装 Python 或开发工具。
最低系统版本：macOS 13。

此测试版采用临时签名，尚未经过 Apple 公证。
若 macOS 拦截首次打开，请在“系统设置 → 隐私与安全性”中查看并允许打开。

接入相机或读卡器，选择设备存储目录，即可扫描视频和照片。
先用可丢弃的测试素材验证转存和清理操作。
INSTALL
hdiutil create -volname 'TrailDrop' -srcfolder "$TASK_STAGE" -ov -format UDZO "$TASK_DMG"
hdiutil verify "$TASK_DMG"
shasum -a 256 "$TASK_DMG" > "$TASK_DMG.sha256"
echo "DMG ready: $TASK_DMG"
