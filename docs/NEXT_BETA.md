# Next beta / 下一阶段

This plan records bounded follow-up work. It does not claim these features have shipped or passed acceptance. Limit each experiment to two implementation/validation rounds; preserve the working fallback and document unsupported configurations when a gate fails.

以下是有边界的后续工作，不代表已经交付或通过验收。每个试验最多两轮实现／验证；未达标准时保留可用回退，记录限制，不降低验收门槛。

## Optical flow / 光流

- Fix correctness before measuring speed: use full-frame reverse-flow correspondence, reset Follow pairing, publish actual pairing only, and schedule all 3× phases at distinct times. Image checks and presentation checks are separate.
- Profile one optimization: share input normalization, luma pyramids and bidirectional flow across the two phases of the same 3× pair. Each phase needs its own output and a lifetime through the final presentation command. Keep only if batch P95 improves at least 10% with no image, ordering or throughput regression.
- Keep strict presentation gates; test 20→60, 30→60, unique 60→120, Follow and engine switching. Separate generation cost, drawable wait, deadline rejection and actual presented counts. Input-to-presentation age can be measured, but it is not HDMI or controller latency.
- Variable 20–30→constant60 needs a target-time-grid resampler, not merely the integer 3× switch. This remains a separate feature.

先修一致性、跟随配对重置、真实倍率发布和3×端点时刻。图像检查不能代替呈现验收。下一次性能试验仅共享同帧对的输入归一化、亮度金字塔和双向光流；相位输出单独保活。完整批次P95改善至少10%且无画质、顺序与吞吐回退才保留。处理耗时、drawable等待、期限拒绝和上屏数分别统计；源到呈现年龄不等于HDMI／操作延迟。20–30波动恒60另需目标时间网格重采样。

## Fitted window preview / 贴合窗口预览

A candidate now implements `Fit over source window (experimental)`, off by default, for a normal desktop window on the same display. Reuse one existing capture stream and renderer, place a borderless preview over the selected source bounds, and let mouse events pass to the source. Returning to MoniView through Dock/app activation restores normal controls. Withdraw on uncertain geometry, source loss, minimize, modal windows or Space changes. Never move, minimize or inject input into the source application.

This can reduce two-window operation; it cannot remove the source game's rendering. Compare the same scene before claiming a GPU or energy reduction. Verify 10 enter/exit cycles, mouse/keyboard control, dialogs and minimize/restore on an actual target application. Reject the prototype if it hides dialogs, misaligns input or loses the escape path after two rounds.

候选代码已实现试验入口，默认关闭，限同显示器的普通桌面窗口：复用单一采集流和renderer，无边框预览覆盖选中源窗口、鼠标穿透；点击Dock／切回MoniView恢复控制。源消失、最小化、几何信息不确定、弹窗或Space变化时撤覆盖。不修改原应用窗口，不注入输入。可减少双窗口操作，不能消除游戏渲染；GPU／功耗收益须同场景对照。实际目标应用验证10次进入退出及输入、弹窗、最小化恢复；两轮仍不可靠就保留独立预览。

Apple documents that independent-window capture retains occluded/off-screen contents, but pauses when minimized: [ScreenCaptureKit window behavior](https://developer.apple.com/videos/play/wwdc2022/10155/). Mouse pass-through uses public [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents).

Apple说明独立窗口在遮挡／屏幕外仍可采集，最小化则暂停。覆盖预览使用公共鼠标穿透API，不承诺跨进程嵌入。

## Mac App Store / Mac商店

Next milestone is an actually sandboxed validation build, not submission. Inspect the signed entitlements and exercise camera/window capture, independent audio, permission recovery, selected-file recording and commit failure. Current local validation builds use a local development signature without sandbox; a resources plist is not proof of enabled sandbox. Non-signing source/privacy preparation and draft metadata are complete as of 2026-10-08; distribution signing, final screenshots, signed hardware acceptance and review remain later tasks. See [App Store preparation](APP_STORE.md).

下一里程碑是实际启用沙盒的验证构建，不是提交商店。检查签名权限并验证采集、独立音频、授权恢复、用户选定文件的录制完成与失败恢复。目前本地验证构建未启用沙盒；资源权限文件不代表实际启用。2026-10-08 已完成非签名代码／隐私准备与文案草稿；分发签名、最终截图、签名包真机验收和审核后续分别处理。

## iPad

Start with one real input→Metal processing→presentation prototype. Pure cadence/presentation policies and Metal processing are reusable candidates; capture adapters, AppKit windows and audio session handling are platform-specific. Do not promise macOS overlay/touch pass-through semantics.

USB-C iPads have supported UVC external input through AVFoundation since iPadOS17: [Apple external-camera guidance](https://developer.apple.com/videos/play/wwdc2023/10106/). Apple's newer [ScreenCaptureKit iOS sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) declares iOS/iPadOS27 and must be evaluated against the selected SDK/device. The current host has macOS SDK26.2 and no selected iPhoneOS SDK, so an iPad build/runtime is not validated here.

先完成一个真实输入到Metal再到呈现的小样，记录持续帧率、延迟和热状态。纯策略与处理模块可复用；采集、AppKit窗口和音频会话分别适配。USB-C iPad可通过AVFoundation接UVC；较新的ScreenCaptureKit iOS示例要求27系统，要按SDK和设备验证。当前主机只有macOS26.2 SDK、没有可用iPhoneOS SDK，未验收iPad构建或实机。不承诺Mac式跨应用覆盖和触摸穿透。
