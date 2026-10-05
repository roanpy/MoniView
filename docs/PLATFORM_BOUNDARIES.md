# Mac / iPad platform boundaries / 平台边界

## Product boundary / 产品边界

MoniView should remain a small live monitor: reliable picture, responsive preview, audio, recording, a frame save command and a few clearly grouped adjustments. Sharing a product across Mac and iPad does not mean duplicating every desktop control or forcing one window implementation onto both platforms.

产品边界仍是小型实时监看器：画面可信、预览及时、音频与录制可靠、能保存当前帧，调节项少而清楚。Mac/iPad 共用产品不等于照搬全部桌面菜单，更不等于让两个平台共用 NSWindow 实现。

## Existing seams, not an already-shared module / 已有切入点，不是已完成的共享模块

- `VideoImageProcessor` contains shared color/sharpening math. `FrameExporter` separates PNG processing/writing from AppKit save UI.
- `DurationBoundedFIFO` and `ConfigurationRevision` depend only on Foundation and have standalone tests.
- `PictureSettings`, capture-option types and `LatestVideoFrame` are candidates for shared files, but currently remain inside `CaptureManager.swift`, which imports AppKit. Do not claim the application is already platform-independent or copy that file wholesale into an iPad target.
- Metal/Core Image processing can be reviewed for reuse behind native view hosts. Availability checks and actual device support remain necessary; macOS availability annotations do not establish iPad support.

图像处理、导出和纯 Foundation helper 已形成可复用边界，但设置模型和最新帧容器仍在带 AppKit 依赖的 CaptureManager 文件中。当前并没有抽好一个可以直接导入 iPad 的完整共享核心；下一阶段只在真实 iPad 目标需要时移动这些类型，保持行为和测试不变。

## Platform adapters / 平台适配

| Area / 领域 | macOS today / 当前 macOS | iPad work to validate / iPad 待验证工作 |
| --- | --- | --- |
| Window and commands / 窗口与命令 | NSWindow, native fullscreen, Window menu, keyboard shortcuts, floating level | SwiftUI/UIKit scene lifecycle, touch and optional keyboard actions; no fake always-on-top equivalent. / 触控与场景生命周期，不虚构窗口置顶对应物。 |
| Preview host / 预览承载 | NSViewRepresentable / MTKView and window occlusion notifications | Native UIKit/SwiftUI host, scene visibility, rotation and external display geometry. / 原生承载、前后台、旋转和外接显示几何。 |
| Capture / 采集 | AVCaptureSession, external-device discovery and format selection | Verify supported external devices, permissions, delivery formats and connection/power requirements on actual iPads. / 用真机确认外设、权限、格式、连接及供电要求。 |
| Audio / 音频 | AVCaptureAudioPreviewOutput | Platform audio-session/routing/interruption policy and an appropriate playback adapter; do not introduce a desktop audio rewrite before validating need. / 音频会话、路由、中断和播放适配。 |
| Export / 导出 | NSSavePanel, file coordination and user-selected access | File exporter/document/share UI, sandbox access and cancellation; reuse image processing, not AppKit UI. / 文件导出/分享、沙盒与取消。 |
| Power / 电源 | ProcessInfo activity assertions | Scene/background/thermal policy appropriate to iPad; verify rather than assume continuous background capture. / 适合 iPad 的前后台与热策略，不假定后台持续采集。 |
| Distribution / 分发 | SwiftPM executable packaged as a Mac app | A real app target, bundle resources, privacy declarations, signing and device acceptance. / 真实 app target、资源、隐私、签名和设备验收。 |

## Incremental sequence / 小步推进

First validate and stabilize the Mac PR batch. Then extract the smallest settings/frame interfaces without changing the renderer. Build a minimal real iPad vertical slice: connect a supported device, show newest-frame preview and verify orientation; only then add audio, recording and export adapters. Keep shared tests runnable without UI frameworks. Every platform addition needs a real build and a device acceptance record.

先完成本批 Mac 构建和真机回归；再最小化迁移设置与帧接口，不重写渲染器。随后做真实 iPad 纵向样例：连接受支持设备、显示最新帧并验证方向，再逐步接音频、录制、导出。不要为未来需求增加插件系统、服务定位器、多层抽象或空壳 target。

No iPad target, iPad hardware test, universal binary or App Store readiness is delivered by this review. Existing licensing and distribution constraints remain unchanged.

本轮没有交付 iPad target、iPad 真机结果、通用二进制或 App Store 就绪认证；现有许可证与分发约束不变。
