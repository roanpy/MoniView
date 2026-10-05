# Changelog

## Unreleased / 未发布

- Align enhancement switches with the panel's right edge; simplify their labels. / 画质面板开关统一右对齐，简化说明。
- Dismiss a successful recording notification after five seconds. Errors and dropped-sample warnings stay visible. / 录制成功提示五秒后消失，错误和丢样本警告保留。

### Fixed

- Redraw is no longer skipped when a settings change, resize, or aspect change arrives while the GPU is still presenting the previous frame; a failed command buffer also requests a redraw instead of freezing on the old image.
- The preview redraws once the window becomes visible again or is un-minimized, even if no new frame arrives.
- The Metal drawable now uses the same color space as the renderer, avoiding a color shift on wide-gamut or color-managed displays.
- A 2K/4K target is now applied to the source's long edge, so portrait signals are no longer over-scaled and 16:9 behavior is unchanged.
- Changing capture devices clears the previous device's format list immediately, so a stale format index can no longer be applied to the new device.
- A failed device switch no longer leaves the device name and resolution showing the previous device; the UI now matches the session state.
- Disconnecting the last capture device also clears the pixel format and frame-rate state.
- An audio-permission callback, or an audio device change, no longer reconfigures the capture session during a recording; the change is applied after the recording finishes.
- Granting camera access in System Settings now clears the denied state when the app becomes active, without a relaunch.

### Changed

- The build workflow is manual-only and no longer runs on push or pull request.

### 修复

- GPU 仍在呈现上一帧时，设置、尺寸或画面比例变化不再丢失重绘；命令缓冲失败时也会请求重绘，不会停在旧画面。
- 窗口重新可见或取消最小化后会补一次重绘，即使没有新帧到达。
- Metal drawable 与渲染使用相同色彩空间，避免宽色域或色彩管理显示器上的偏色。
- 2K/4K 目标改为按源画面长边计算，竖屏信号不再被过度放大，16:9 行为不变。
- 切换采集设备时立即清空上一台设备的格式列表，旧格式索引不会再被应用到新设备。
- 切换设备失败后，界面不再残留上一台设备的名称和分辨率，状态与 session 保持一致。
- 断开最后一个采集设备时，一并重置像素格式与帧率状态。
- 音频权限回调或音频设备切换不再在录制期间改动采集 session，改为录制结束后应用。
- 在系统设置中授予摄像头权限后，应用恢复活跃时即清除拒绝状态，无需重启。

### 变更

- 构建 workflow 改为仅手动触发，不再在 push 或 PR 时运行。

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
