# Changelog

## v0.2.0 — English

First public release. This is an ad-hoc signed local build; it is not on the Mac App Store.

### Added

- Native macOS UVC (HDMI capture card) preview built on SwiftUI, AVFoundation, Metal, and Core Image, with no third-party runtime dependencies.
- Device-reported format enumeration, including discrete steps and fractional rates such as 29.97 and 59.94 FPS.
- Audio monitoring of the capture card's input with a level meter.
- Recording to H.264 video with AAC audio in a `.mov` file.
- Color controls (brightness, contrast, saturation, vibrance, highlight recovery) and sharpening.
- GPU spatial scaling with MetalFX and a Lanczos fallback; targets are original, 2K, and 4K.
- Aspect modes: fit, fill, and stretch, plus native full screen.
- A local diagnostics snapshot at `~/Library/Logs/MoniView/diagnostics.json`.
- A bundled privacy manifest (`Resources/PrivacyInfo.xcprivacy`).
- Interface follows the system language: English or Simplified Chinese.
- Preview rendering pauses while the window is minimized or fully occluded; capture, recording, and audio monitoring continue.

### Changed

- Recording includes the selected color adjustments and sharpening at the original resolution by default; GPU scaling and the on-screen UI are never written to file. A settings toggle saves the untouched source instead.
- The brief status line (device, buffer resolution, FPS) sits centered along the top in window mode and moves to the top left in full screen; the detailed info card hides it while open.
- H.264 encoding uses the system encoder through AVFoundation; a hardware encoder is not guaranteed.

### Fixed

- The video connection frame duration follows the device, so a device set to 60 FPS is not left with a 20 FPS connection.
- When the resolution changes and the current frame rate is unsupported, the highest rate of the new format is used.

## v0.2.0 — 简体中文

首个公开发布版本。这是 ad-hoc 签名的本机构建，未上架 Mac App Store。

### 新增

- 基于 SwiftUI、AVFoundation、Metal 与 Core Image 的原生 macOS UVC（HDMI 采集卡）预览，无第三方运行库。
- 按设备上报的格式枚举分辨率与帧率，支持离散档位和 29.97 / 59.94 等非整数帧率。
- 采集卡音频输入实时监听与电平显示。
- 录制 H.264 视频 + AAC 音频的 `.mov` 文件。
- 色彩调节（亮度、对比度、饱和度、鲜艳度、高光恢复）与锐化。
- MetalFX GPU 空间放大与 Lanczos 回退；放大目标为原始、2K、4K。
- 画面比例：适应画面、填满窗口、拉伸填满；原生全屏。
- 本机诊断快照 `~/Library/Logs/MoniView/diagnostics.json`。
- 打包的隐私清单（`Resources/PrivacyInfo.xcprivacy`）。
- 界面跟随系统语言：简体中文或英文。
- 窗口最小化或被完全遮挡时暂停预览渲染，采集、录制和音频监听继续进行。

### 变更

- 录制默认包含所选色彩调节和原始分辨率的锐化；GPU 放大和界面叠层不写入文件。可在设置中关闭，保存未经处理的原始画面。
- 简要状态条（设备、缓冲分辨率、FPS）窗口模式顶部居中，全屏移到左上；详细画面信息卡打开时隐藏该状态条。
- H.264 编码通过 AVFoundation 使用系统编码器，不保证使用硬件编码器。

### 修复

- 视频连接的帧间隔跟随设备设置，避免设备设为 60 FPS 而连接仍为 20 FPS。
- 切换分辨率时若当前帧率不支持，自动使用新格式的最高档。
