# Mac window enhancement feasibility / Mac 本机窗口增强可行性

Status: researched proposal, **not implemented**. The current product still uses capture-device input. / 状态：已研究的方案，**尚未实现**；当前产品仍使用采集设备输入。

## Recommendation / 建议

An optional Mac-window source is technically feasible: capture a selected game/software window with Apple's ScreenCaptureKit, then show its enhanced copy in MoniView. This can reuse spatial processing and, after separate validation, midpoint interpolation. It does not increase the original application's engine FPS or change its rendering resolution. It must not be advertised as equivalent in quality, compatibility or performance to Lossless Scaling. / 可用 ScreenCaptureKit 捕获选定游戏或软件窗口，在 MoniView 中显示增强副本；可复用空间处理，经独立验收后再接插帧。不会提高原应用引擎帧率或改变其渲染分辨率，不宣称效果、兼容性或性能等同小黄鸭。

Keep the five existing controls. Add only a source choice in settings: Capture device / Mac window. Start with the system content-sharing picker and one selected window, rather than desktop-wide capture, game injection or a plugin system. / 保留五个入口，只在设置中增加“采集设备／Mac 窗口”；优先系统窗口选择器及单窗口，不增加游戏注入或插件框架。

## Proposed pipeline / 拟议处理链路

Selected window → ScreenCaptureKit sample callback → validated timestamp, size and color metadata → latest-frame overwrite → spatial enlargement or optional 2× midpoint generation → actual drawable-presentation counters.

选定窗口 → ScreenCaptureKit 帧回调 → 核对时间戳、尺寸及颜色信息 → 最新帧覆盖 → 空间放大或可选 2× 中间帧 → 实际呈现回调统计。

Use a small Mac-specific capture adapter, with the existing frame handoff as its boundary. Screen callbacks must not manipulate MTKView. Retain only frames required by the in-flight work and interpolation reference; promptly return unneeded capture surfaces. Apple's minimum-frame-interval setting is a requested capture cadence, not proof of game FPS. Idle or variable-rate content needs conservative eligibility and native fallback, rather than invented timestamps or repeated pictures counted as generated frames. / 增加小型 Mac 采集适配器，复用帧交接边界；回调不操作 MTKView，及时释放不再需要的采集 surface。请求采集帧率不是游戏帧率证明；静止或可变节奏输入须保守准入并回退，不伪造时间戳或把重复画面算作生成帧。

## Constraints to validate / 必须验证的限制

| Area / 领域 | Consequence / 影响 |
| --- | --- |
| Permission / 授权 | Use the system-selected content and handle session cancellation or revocation. Do not capture before an explicit selection. / 按系统选择范围采集，处理取消及撤销，不预先捕获。 |
| GPU sharing / 共用 GPU | The source game and enhancement compete on the same Mac. Additional work may reduce source FPS; compare the game with capture off, capture only, spatial scaling and interpolation separately. / 游戏与增强争用同一 GPU，须分别测量关闭捕获、仅捕获、超分、插帧。 |
| Latency / 延迟 | Capture, processing and presentation add delay. Interpolation also needs a later frame; output FPS alone does not measure response improvement. / 捕获、处理和上屏增加延迟，插帧还须等待后帧；输出 FPS 不代表响应更快。 |
| Focus and input / 焦点与输入 | Showing an enhanced window can affect the game's focus or background rendering. First validate keyboard/controller use; universal mouse-coordinate forwarding is a separate feature, not assumed working. / 增强窗口可能影响游戏焦点及后台渲染，先验证键盘／手柄；不假定所有软件都能正确转发鼠标坐标。 |
| Feedback / 递归捕获 | Capture only the source window and exclude MoniView's output. Changing or closing the source invalidates its stream epoch and pending work. / 排除 MoniView 增强输出；换源或关闭源窗口使旧流及待处理任务失效。 |
| Image format / 图像格式 | Screen input may differ from UVC YUV. Verify BGRA/YUV conversion, alpha, color space, orientation and backing scale; never invent missing metadata to force a fast path. / 核实屏幕输入的格式、透明度、色彩空间、方向及绘制尺寸，不补造元数据。 |
| Compatibility / 兼容性 | Fullscreen transitions, capture-excluded/protected content and applications that stop rendering in the background need real tests and clear fallback. / 全屏切换、不能捕获的内容及后台停渲染应用需真机验证与明确回退。 |
| iPad / iPad | Reuse processing only after checking the actual platform SDK and device support. Mac inter-application capture and input/window behavior are not an established iPad feature. / 处理核心是否复用须核对 iPad SDK 及真机，Mac 跨应用捕获、输入及窗口行为不能直接视为 iPad 已具备。 |

## Incremental acceptance / 分步验收

1. Implement selected-window capture with enhancement off. Verify permission cancellation, window closure/resize, source switching, self-exclusion and bounded surface ownership. / 先完成原始窗口捕获及其生命周期。
2. Enable MetalFX using the existing controls. Compare static text and moving edges at the same input/output size; measure the source game's impact and processing-to-presentation interval. / 再接空间增强，同条件对比细节与源游戏负担。
3. Enable optional 2× interpolation only for a stable supported cadence. Measure actual source/generated/output presentations and spacing; test source FPS drops, occlusion, display changes and overload. No blanket 60→120 promise. / 最后接可选 2×，测实际帧数、间隔及异常回退，不承诺普遍 120。
4. Validate at least one ordinary software window and one game before treating it as a shipped feature. Keep UVC and local-window acceptance records separate. / 至少验证一个软件窗口和一个游戏，分别记录 UVC 与本机窗口验收。

## Primary references / 一手资料

- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) — selected-window filters and stream configuration.
- [Apple: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/) — surface ownership, bounded queues and frame loss when surfaces are held too long.
- [Apple: What's new in privacy](https://developer.apple.com/videos/play/wwdc2023/10053/) — SCContentSharingPicker grants access to explicitly selected content for the capture session.
- [Apple: Low-latency frame interpolation configuration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration) — runtime availability and temporal/spatial processing boundaries.

These APIs establish feasibility, not App Store approval, universal compatibility, sustained performance or measured latency. / 接口资料说明可行性，不代表上架批准、普遍兼容或已经实测的性能与延迟。
