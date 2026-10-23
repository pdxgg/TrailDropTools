# 轻舟 TrailDrop

![轻舟应用图标](assets/traildrop-icon.svg)

轻舟是一款离线的 macOS 运动影像转存工具。连接相机或读卡器后，可以扫描照片和视频、按需批量转存，或按时间范围全量转存。转存时保留原片、原文件名与已识别的关联文件；设备原文件默认保留，清理需要在独立页面手动确认。

**当前版本：0.1.3 测试版。Mac 可实际转存；Windows PC 和 Android 只展示目标路径规划，尚无这两端的转存应用。**

## 获取与使用

- Apple Silicon 本机测试安装包在构建后位于 `build/TrailDrop-0.1.3-arm64.dmg`。仓库不提交构建产物；GitHub Actions 构建完成后也会提供临时下载 Artifact。
- 打开 DMG，将 `TrailDrop.app` 拖入 Applications。安装包内含运行时，终端用户无需安装 Python。
- 在相机上选择文件传输模式，使存储作为磁盘挂载。点击“扫描已连接设备”；若没有候选设备，可点“选择设备目录”。扫描只读，不会自动复制或清理。
- 在“批量转存”逐项或逐天调整选择，或在“全量自适应”按日期范围选择。先看路径预览，再选择 Mac 保存目录并开始转存。
- 转存完成后如需释放设备空间，进入“设备清理”单独选择。未备份素材的强制清理有二次确认。首次使用请先用可丢弃的测试素材核对结果。

路径预览显示设备原文件、Mac 预计或已有副本位置。每张素材卡片的“查看路径”可以切换示例；Windows PC 与手机规划路径在可展开区域中，并明确标为尚未实现转存。Mac 路径中的 `<转存时间_短码>` 会在开始时变为实际批次目录；断点恢复和去重时以最终完成记录为准。

## 文档

- [完整需求与交互设计](docs/完整需求与交互设计.md)：产品范围、三大流程、路径规则、本轮需求变化、修正问题、验收与 Windows/Android 路线。
- [本机验证记录](VALIDATION.md)：自动测试、临时素材与 DJI Osmo Action 4 只读扫描的实际结果，以及未覆盖项目。
- [阶段性开发计划](产品设计与开发计划.md)：早期方案和实施里程碑；完整需求以新版文档为准。
- [Logo 源文件](assets/traildrop-icon.svg)：Mac 图标由构建脚本生成并嵌入应用。

## 项目结构

```text
Core/engine.py                  扫描、转存、校验、断点、清理引擎
Mac/TrailDropApp.swift          SwiftUI 主窗口与交互
Mac/Info.plist                  应用名称、版本和权限说明
assets/traildrop-icon.svg       应用图标设计源文件
scripts/generate-icon.sh        SVG → PNG 尺寸集 → ICNS
scripts/build-mac.sh            构建并临时签名 Mac 应用
scripts/package-dmg.sh          生成和校验 DMG
scripts/smoke-mac.py            内嵌引擎临时素材烟测
Tests/test_engine.py            文件引擎自动测试
.github/workflows/build-mac.yml macOS CI 构建
docs/完整需求与交互设计.md      完整产品需求与交互规则
```

## 本机从源码构建

需要 macOS、Xcode Command Line Tools、Python 3.9+；构建时另需 PyInstaller 6.16。脚本使用当前 Mac 的架构生成应用和 DMG。

```bash
python3 -m unittest discover -s Tests -q
python3 -m venv .venv
.venv/bin/python -m pip install 'pyinstaller==6.16.0'
PYINSTALLER_CONFIG_DIR="$PWD/build/pyinstaller-config" .venv/bin/python -m PyInstaller --noconfirm --clean --onefile --name traildrop-engine --distpath build/runtime --workpath build/pyinstaller --specpath build Core/engine.py
CI=true bash scripts/build-mac.sh
python3 scripts/smoke-mac.py
bash scripts/package-dmg.sh
```

应用构建脚本会从 SVG 生成图标。生成物位于 `build/`，已被 `.gitignore` 排除。GitHub Actions 在 `main` 分支推送或手动触发时分别尝试 arm64 和 x86_64 构建，并上传临时安装包；CI 成功不等于各型号实机验收。

## 实现与已知边界

SwiftUI 负责原生界面；本地 Python 引擎通过 JSON Lines 与应用通信，使用 SQLite 记录副本和断点，并通过 SHA-256 验证复制结果。当前来源必须挂载为 Mac 可读取的普通磁盘；MTP/PTP 与 Wi‑Fi 直传未实现。部分专有媒体的缩略图与播放依赖 macOS 解码能力，EXIF/QuickTime 拍摄时间解析仍待实现。

本测试版采用临时签名，未公证。已经在本机 Apple Silicon 上构建并启动；macOS 13 最低版本、Intel Mac、无开发环境的其他 Mac，以及真实 Action 4 文件复制和清理仍需验证。不要把 Action 4 已成功只读扫描理解为已验证真实设备清理。Windows 和 Android 的目录、权限和传输方式将在各自实现阶段确定。
