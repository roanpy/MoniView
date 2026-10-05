<div align="center">

# MoniView

**原生、轻量的 macOS UVC / HDMI 采集卡监看器。**

实时预览、音频监听、录制、色彩工具与 MetalFX 空间放大，基于 SwiftUI、AVFoundation、Metal 与 Core Image，不依赖第三方运行库。

**[English](README.md) · 简体中文**

[![Build](https://github.com/roanpy/MoniView/actions/workflows/build.yml/badge.svg)](https://github.com/roanpy/MoniView/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-f05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-16a34a.svg)](LICENSE)

</div>

> **状态：早期预览（0.2.0）。** MoniView 是本机 ad-hoc 签名的开发版，未做公证，未上架 Mac App Store。支持 macOS 14 及以上。界面跟随系统语言：简体中文或英文。

MoniView 把 USB（UVC）采集卡变成 HDMI 信号源的低延迟监看窗口，适用于相机、游戏主机和其他 HDMI 输出设备。

## 功能

- 按设备实际上报的格式枚举分辨率与帧率，支持离散档位和 29.97 / 59.94 等非整数帧率。
- 预览只保留最新帧；采集、GPU 渲染、音频与视频编码使用独立队列，GPU 最多一帧处理中。
- 实时监听采集卡音频输入，并显示电平。
- 录制 H.264 + AAC 的 `.mov` 文件。
- 色彩与锐化调节：亮度、对比度、饱和度、鲜艳度、高光恢复。
- 使用 MetalFX 在 GPU 上放大预览，并提供 Lanczos 兼容回退。
- 诊断快照仅写入本机。

## 截图

![MoniView 等待摄像头授权的窗口](docs/images/moniview-window.png)

此图来自实际运行的 app，显示等待 macOS 摄像头授权时的窗口和按钮样式，不代表实时采集画面或性能基准。完成硬件授权与验证后再补充实时预览及设置页截图。

## 构建与运行

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

只需要 Swift 工具链，Xcode Command Line Tools 即可，不需要 Xcode 工程或完整 IDE。`Scripts/build-app.sh` 把 SwiftPM release 产物打包成 `build/MoniView.app`，包含 `Resources/MoniView.icns` 和打包的 `PrivacyInfo.xcprivacy`，并做 ad-hoc 签名。

首次启动需授权摄像头和麦克风（采集卡音频也使用麦克风权限）。MoniView 自动选择 USB 视频设备和匹配的音频输入；其他输入可在设置中选择。

底部按钮：录制、画面信息、画质增强、色彩、设置。点击画面关闭已打开的面板。

简要状态条显示设备名、实际缓冲分辨率和实测 FPS：窗口模式居中于顶部，全屏时移到左上角。详细画面信息卡打开在右上角，打开时隐藏简要状态条，关闭后恢复。可在设置中用「显示设备状态」关闭简要状态条。

「画面比例」决定画面如何填满窗口：适应画面（完整显示）、填满窗口（保持比例、裁切超出部分）、拉伸填满（铺满窗口，画面比例可能变形）。

快捷键：`⌘R` 录制/停止，`⌘M` 静音监听，`⌘I` 显示/隐藏信息卡，`⌘,` 打开设置，`⌃⌘F` 或双击画面切换原生全屏，`Esc` 关闭面板或退出全屏。全屏静止 3 秒隐藏按钮和鼠标，移动恢复。

## 画面与帧率

MoniView 同时设置设备和视频连接的帧间隔，避免设备设为 60 但连接仍输出 20。切换分辨率时若原帧率不支持，会自动使用新格式最高档。

右上信息卡显示实际缓冲尺寸、采集/渲染帧率、音频电平和软件处理耗时。该耗时从视频回调到 GPU 完成，不包含 HDMI 设备、采集卡与屏幕扫描延迟。

窗口最小化或被其他窗口完全遮挡时暂停预览渲染，采集、录制和音频监听继续进行。

处理链路、单机实测快照和测量边界见[性能说明](docs/PERFORMANCE.md)。

## GPU 空间放大不是 AI

MetalFX 空间放大器不需要多帧历史，无法创造采集信号里没有的真实细节。此版不含 AI 模型或插帧。

- **MetalFX**：支持的 GPU 使用系统空间放大器。
- **Lanczos**：兼容路径；设备不支持 MetalFX 或放大比例超过其当前限制时自动回退。
- 目标：原始（随窗口）、2K（2560×1440）、4K（3840×2160）。尺寸按 16:9 举例，其他比例保持原比例。

低延迟模式下放大的目标是上限：按实际显示尺寸处理，而不是始终按完整目标尺寸。关闭垂直同步时可能出现画面撕裂；关闭低延迟模式即可始终按完整目标尺寸处理。

这些功能只影响实时预览。

## 录制

录制默认包含所选色彩调节和原始分辨率的锐化，不包含 GPU 放大或界面叠层。锐化按原始分辨率应用，而预览可能在 MetalFX/Lanczos 放大后再锐化，因此录制文件不会与放大后的预览逐像素一致。在设置中关闭「录制预览色彩和锐化」即可保存未经处理的原始画面。H.264 编码通过 AVFoundation 使用系统编码器，可能是硬件或软件编码器，不保证使用硬件编码器。有音频时使用 AAC，封装为 `.mov`。

## 实测设备上限

在开发机上实测 Jemdo Video USB 采集设备：设备暴露的最高采集格式为 1920×1080、约 60 FPS，没有 4K 采集条目。HDMI 输入/直通规格与 USB 采集输出规格可能不同，以设备实际上报的格式为准；其他采集卡仍需在对应硬件上验证。

这是一台设备上的实测结果，不是通用性能承诺。

## 隐私

必须授权摄像头和麦克风：摄像头权限用于读取 UVC 采集卡，麦克风权限用于读取采集卡音频输入以进行监听和录制。MoniView 完全在本机运行，不收集数据，也不向外部服务发送数据。app 打包了隐私清单（`PrivacyInfo.xcprivacy`），声明不跟踪、不收集数据。录制保存到你在存储面板中选择的文件，诊断快照写入 `~/Library/Logs/MoniView/diagnostics.json`，都只留在本机。采集卡序列号、设备标识和诊断日志可能包含可识别信息，请勿附到公开 issue 中。完整说明见 [docs/PRIVACY.md](docs/PRIVACY.md)。

## 平台与路线

当前仅 macOS，以 ad-hoc 签名的本机构建分发，未做公证，也不是 Mac App Store 构建，当前产物不能直接用于 Store 提交；分发清单与当前缺口见 [docs/APP_STORE.md](docs/APP_STORE.md)。iPad 版需要独立的 UIKit/触控目标、音频播放适配与单独签名；Mac 的 `.app` 不能安装到 iPad。iOS 版本不在本仓库，后续版本可能闭源；已发布版本沿用发布时的许可证。

## 参考

以下资料仅用于采集与渲染方案的对照，未复制任何第三方代码。OBS Studio 采用 GPL-2.0-or-later，仅参考其实现思路，未使用其源码。

- Apple：[Technical Note TN2445 — Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- Apple：[CAMetalLayer](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer) 与 [nextDrawable()](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer/nextDrawable())
- OBS Studio：[mac-avcapture 插件](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-avcapture)（GPL-2.0-or-later）

## 参与贡献

构建与隐私约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，版本历史见 [CHANGELOG.md](CHANGELOG.md)。GitHub Actions 只做构建。

## 许可证

MIT，见 [LICENSE](LICENSE)。
