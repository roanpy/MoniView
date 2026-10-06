# Changelog

## Unreleased / 未发布

- Reuse conforming IOSurface interpolation inputs at native working size; reject unspecified/conflicting chroma locations instead of guessing. / 同尺寸插帧直接保活满足条件的 IOSurface 输入；未知或冲突的色度位置继续走转换。
- Include encode-to-completion waits in interpolation budgets without adding elapsed time twice; clear stale running status on deadline fallback. / 插帧预算包含编码至完成回调的等待且不重复累加；呈现期限回退时清除过期运行状态。
- Prune spatial-scaler failure keys periodically and add an optimized spatial/interpolation GPU matrix plus strict visible-window validation. / 周期清理空间放大失败键，新增优化编译的离屏兼容性矩阵与严格可见窗口验收。

- Add experimental, off-by-default Apple GPU midpoint interpolation with adaptive sizing, display-link timing checks, measured budget fallback and bounded presentation recovery. / 新增默认关闭的实验性 Apple GPU 中间帧插帧，支持自适应处理尺寸、显示链路周期核查、预算回退和有界呈现恢复。
- Keep spatial scaling available during interpolation; pause the standalone AI scaler and preserve its preference. Source recording and PNG FPS/dimensions remain unchanged. / 插帧时保留空间放大，暂停独立 AI 超分并保留偏好；源录制与 PNG 帧率、尺寸不变。
- Reduce Smooth midpoint work with fast fallback input resampling and a single final resize; retain original source rendering and Clear quality. Keep the spatial status badge stable and explain the standalone AI pause. / 流畅档采用较轻的回退输入缩放和一次最终缩放，保留原帧渲染与清晰档质量；稳定空间处理标签，并说明独立 AI 暂停状态。

- Fix native AI black output, swapped channels and upside-down rows; retain render resources through GPU completion and wake retries without new frames. / 修复 AI 黑屏、红蓝交换与上下颠倒，保活渲染资源，并让静止输入也能重试。
- Add optional 1080p processing target, separate enhancement-label visibility and hidden-by-default status. / 新增 1080p 处理目标，增强标签独立显示开关，状态默认隐藏。
- Validate precise format priority, non-USB discovery fallback, output pixel formats after negotiation, and rollback a failed audio switch. / 核对精确格式优先级、非 USB 默认选择、协商后像素格式，并回滚失败的音频切换。
- Add native audio fault injection and GPU color/orientation tests; clean up a finished temporary recording on commit failure. / 新增原生录音故障注入与 GPU 色彩方向测试，提交失败时清理临时录制文件。

- Add a media-duration-bounded recording audio FIFO with oldest-first eviction, drop accounting and bounded tail draining. / 录制音频增加按媒体时长限制的 FIFO、丢最旧计数与有界尾音排空。
- Add File > Save Current Frame and Command-S for source-resolution PNG export with current color and sharpening. / 新增文件菜单与 ⌘S 保存当前画面为源分辨率 PNG，包含当前色彩与锐化。
- Add a persistent Always on Top preference for the main preview window. / 新增主预览窗口置顶偏好并持久化。
- Correct AI setup retry scheduling, configuration invalidation and GPU resource ownership; keep unsupported configurations on the spatial fallback. / 修复 AI 初始化重试、配置失效与 GPU 资源生命周期，不支持时保持空间放大回退。
- Make the optional AI path buildable separately from older-toolchain fallback; packaging accepts MONIVIEW_DISABLE_AI=1. / 区分可选 AI 与旧工具链回退构建，打包支持 MONIVIEW_DISABLE_AI=1。
- Measure completion before the final main-thread hop, deduplicate frame statistics, and redraw when display/backing properties change. / 在最后一次主线程跳转前计时、按采集帧去重统计，换屏或绘制缩放变化时重绘。
- Correct fractional-rate selection, actual buffer-format labels, localized engine names and long-edge/display wording. / 修正分数帧率选中状态、实际缓冲格式、引擎本地化和长边/屏幕说明。
- Synchronize capture configuration revisions and reject superseded format-error callbacks. / 同步采集配置代次并拦截过期格式错误回调。
- Add executable pure Swift regression tests and a hardware-validation/local-AI handoff guide; no new hardware benchmark is claimed. / 增加可执行纯 Swift 回归测试与真机验收/本地 AI 接手说明，不声称新增硬件基准结果。
- Fix AI super-resolution never engaging: the frame pool forced BGRA while the system scaler only accepts bi-planar YUV at supported sizes, so setup always fell back to MetalFX; frames now convert through a private BGRA intermediate and a Metal compute kernel to video-range BT.709 420v. / 修复 AI 超分始终不生效：缓冲池强制 BGRA，而系统超分在支持尺寸内仅接受双平面 YUV，导致始终回退 MetalFX；现经私有 BGRA 中间纹理与 Metal 计算内核转换为视频范围 BT.709 420v。
- Fix resolution/format selection not taking effect: writing output videoSettings renegotiates the capture session and reverts the device format, and starting the session re-selects the preset format; output settings are now written only when the pixel format changes and before selecting the format, and the chosen format is re-asserted after the session starts. / 修复分辨率/格式切换不生效：写输出 videoSettings 会触发会话重新协商并回退设备格式，且启动会话时按预设重选格式；现仅在像素格式变化时写输出设置并先于选定格式写入，会话启动后重新应用所选格式。

- Optional AI super-resolution upscaling via Apple's low-latency ML scaler on macOS 26+, with MetalFX fallback while the model loads. / macOS 26+ 可选 AI 超分放大（Apple 低延迟机器学习超分），模型加载期间自动回退 MetalFX。
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

## Unreleased (2)

- The preview redraw is now deduplicated against the last submitted draw and re-checked on the main thread when the GPU finishes, so a state change made while the GPU was busy, a restored window, or a failed command buffer all end in a correct redraw without busy retrying.
- Video device switching and format changes carry a configuration generation; a result from a superseded switch can no longer publish stale device state or apply another device's format index. A failed switch now leaves the session and the UI in one consistent state.
- Recording writes to a unique temporary file beside the destination and moves it into place only after the writer finishes, so choosing "Replace" in the save panel now works and an existing recording is never truncated by a failed attempt.
- The recording color path is fixed when recording starts. A shortage of processing resources now fails the recording instead of silently writing unprocessed frames that were still tagged as BT.709.
- The info card reports the actual processed size next to the selected target, so a 2K/4K target is no longer mistaken for that output size. In low latency mode the target is a cap bounded by the visible size, and 2K and 4K can resolve to the same processing size.

### 变更（二）

- 预览重绘改为按最近一次已提交的绘制去重，并在 GPU 完成时回到主线程重新判断，因此 GPU 忙时的设置变更、窗口恢复、命令缓冲失败都会最终得到一次正确重绘，且不会空转重试。
- 视频设备切换与格式修改带有配置代次，被取代的切换结果不再发布过期设备状态，也不会把别的设备的格式索引应用过来；切换失败后 session 与界面状态保持一致。
- 录制改为先写入目标同目录的唯一临时文件，writer 成功完成后再移动就位。保存面板选择替换现在可正常工作，录制失败也不会截断已有文件。
- 录制开始时固定色彩处理路径。处理资源不足时录制会明确失败，不再静默写入未处理却仍标记 BT.709 的画面。
- 信息卡在所选目标旁显示实际处理尺寸，避免把 2K/4K 目标误认为实际输出尺寸。低延迟模式下目标是受可见尺寸限制的上限，2K 与 4K 可能得到相同处理尺寸。

### Added

- Color sliders, the monitoring volume slider, and the audio level meter expose accessibility labels and values.
- `Scripts/build-app.sh` accepts version, build, architecture, signing identity, and entitlement overrides, verifies the signed bundle, checks bundled resources, and reports the produced architecture and version.

### Changed

- The privacy statement no longer claims both permissions are mandatory: camera access is required for video, and microphone access is only needed to monitor or record audio.

### 新增

- 色彩滑块、监听音量滑块与电平条补充了辅助功能标签和取值。
- `Scripts/build-app.sh` 支持版本、构建号、架构、签名身份与 entitlements 覆盖参数，并校验签名产物、检查打包资源、输出实际架构与版本。

### 变更（三）

- 隐私说明不再声称两项权限都是必需：视频需要摄像头权限，只有监听或录制声音时才需要麦克风权限。

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
