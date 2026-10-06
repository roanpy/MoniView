# Optional preview frame interpolation / 可选预览插帧

## Contract / 行为边界

This feature is off by default and requires the public VideoToolbox low-latency frame processor on a supported macOS 26+ GPU. It generates one midpoint between two source frames: a **2× target**, not a guarantee that every midpoint reaches the screen. The info card reports generated frames from actual drawable-presented callbacks. Capture FPS, recording and PNG export remain based on original source frames. Source quality, gameplay input latency and HDMI-to-screen latency are not improved merely by generating frames.

默认关闭，需要 macOS 26+ 和系统支持的 GPU。使用 Apple 公开 VideoToolbox 低延迟处理器生成两个原帧之间的一张中间帧：**目标为 2×，不保证每张生成帧都能呈现**。信息卡的生成帧数来自实际呈现回调。采集、录制和 PNG 导出仍以原始输入帧为基础；插帧不会凭空提高源画质或降低操作、HDMI 到屏幕的总延迟。

## Independent dimensions / 三种尺寸分开

| Layer / 层级 | Policy / 规则 |
| --- | --- |
| Capture input / 采集输入 | Select actual device-advertised format and fractional FPS. A 4K HDMI specification is not proof of 4K USB capture. / 按设备上报格式及精确帧率选择；4K HDMI 规格不等于 4K USB 采集。 |
| Interpolation / 插帧 | Efficient starts with a 1280 long-edge cap, or 960 when input is above 40 FPS. Repeated P95 budget failures step its cap down through 1280→960→854→640. Preserve aspect ratio, round each dimension down to even, and never enlarge smaller input. Show the actual working dimensions. Quality stays capped at 1920 and is never automatically downscaled. / 流畅档默认长边上限 1280；输入超过 40 FPS 时从 960 开始。P95 预算持续超限时依次降到 960→854→640（低帧率起始档还包括 1280→960）。保持比例、各边向下取偶数，不放大小输入，并显示当前实际工作尺寸。清晰档上限 1920，不自动降低工作尺寸。 |
| Spatial output / 显示放大 | Original, 1080p, 2K, 4K or Match Display. Targets are processing caps; low-latency mode limits them to the visible pixel size. / 原始、1080p、2K、4K 或匹配屏幕都是处理上限；低延迟模式限制到实际可见像素尺寸。 |

For example, 720p input can be interpolated at its original size and spatially enlarged to 1080p/2K/4K. 4K input can use a lower-resolution midpoint while retaining original 4K source endpoints. This can make alternating-frame detail differ: it is a deliberate resource/quality tradeoff, **not native 4K interpolation**. Unsupported dimensions, unstable cadence or excessive cost fall back to source frames. Portrait and non-16:9 sources retain aspect ratio.

例如，720p 输入可按原始尺寸插帧后放大到 1080p/2K/4K；4K 输入可生成较小尺寸的中间帧并保留原始 4K 端点。交替帧的细节可能不一致，这是资源与画质的取舍，**不是原生 4K 插帧**。系统不支持尺寸、输入节奏不稳定或处理过重时回退原帧；竖屏及非 16:9 输入保持比例。

## Refresh and cost / 刷新率与负担

Admission checks stable increasing media timestamps, the current window's screen limit and the system-reported display-link period. It does not infer refresh rate from a Mac model, GPU name, selected capture FPS or a display's marketing maximum. ProMotion is adaptive; a 120 Hz capable panel configured to fixed 60 Hz cannot display 120 FPS. Cross-screen/backing/visibility changes invalidate scheduling assumptions. A native Display Settings link lets the user change the OS setting; the app does not silently change global settings.

准入同时检查稳定递增的媒体时间戳、窗口所在显示器的当前上限和系统报告的显示链路周期；不依据 Mac 型号、GPU 名称、选定采集帧率或宣传值猜测。ProMotion 是自适应刷新，支持 120 Hz 的面板设为固定 60 Hz 时不能显示 120 FPS。跨屏、缩放及可见性改变会重置调度假设。提供系统显示器设置入口，由用户选择全局设置。

A 60 FPS source on a 120 Hz display has an 8.33 ms presentation slot; 30→60 has 16.67 ms. The per-slot gate allows the measured CPU-encode plus GPU-execution P95 for either midpoint or endpoint to use at most 90% of its slot. A separate pair gate requires midpoint P95 plus endpoint P95 to fit within 80% of the complete two-slot/source-frame cycle. The 80% limit applies to the pair, not independently to every slot. The indicator uses up to 32 steady-state samples; two measured native-only startup warmups are separate. Overload triggers cooldown and, in Efficient mode only, adaptive working-size reduction. These are processing budgets, **not total system GPU utilization**; they exclude drawable acquisition/presentation delay, capture transport and HDMI latency. Other GPU work and output scaling can affect actual presentation.

60→120 的每个呈现时隙约 8.33 ms，30→60 约 16.67 ms。单时隙门限允许中间帧或端点各自的 CPU 编码加 GPU 执行 P95 最多占该时隙 90%；另有整周期门限，要求中间帧 P95 与端点 P95 之和不超过完整两时隙／源帧周期的 80%。80% 约束作用于这对工作总和，不是每个时隙分别按 80% 准入。提示使用最多 32 个稳态样本；两次有实测成本的原帧校准预热单独处理。超限会冷却回退，只有流畅档会自适应降低工作尺寸。这些是处理预算，**不是整机 GPU 占用率**；不包含 drawable 获取及实际上屏延迟、采集传输或 HDMI 延迟。其他 GPU 工作和放大目标都会影响实际呈现。

Interpolation needs the current source before computing its midpoint, and delays its endpoint until after that midpoint. This adds capture-period/display-alignment latency even when inference is fast. Disable interpolation for the lowest interactive latency. Two cost tiers do not constitute a universal quality or performance certification.

必须收到当前源帧才能生成中间帧，随后再呈现端点，因此即便推理很快，也会增加采集周期与显示对齐相关的延迟。最低操作延迟应关闭插帧；两个档位不代表跨设备性能或画质认证。

## Composition and resource lifetime / 组合与资源生命周期

Color and sharpening apply once after midpoint generation. MetalFX/Lanczos spatial enlargement remains available. The standalone AI super-resolution session is suspended while interpolation is selected; its preference is retained. Apple also offers joint temporal/spatial interpolation, but that API restricts the joint path to 2× spatial scaling and one generated midpoint. It has not been enabled or certified here. Independent 3×/4× temporal processing requires separate presentation/budget/quality acceptance; successful one-shot processor calls are not throughput proof.

生成中间帧后只执行一次色彩及锐化，可继续使用 MetalFX/Lanczos 空间放大。选择插帧期间暂停独立 AI 超分会话，保留原有选项。Apple 另有联合时间／空间处理接口，但联合路径仅支持 2× 空间放大及一张中间帧；当前未启用、未认证。独立 3×/4× 插帧还需分别验证呈现、负担与画质，单次处理成功不是实时性能证明。

Normal preview retains only the latest source. Interpolation additionally retains one preceding reference and one fixed pending endpoint, with no accumulating capture queue. A shared semaphore limits GPU submissions to one in flight, while presentation tokens separately cap future unpresented drawables at three. Completion resources retain sessions, pixel buffers, texture references and CI tasks through GPU completion, including partial failure. Presentation deadlines cover generated/source/fallback frames across setting changes. A lost presentation callback after GPU completion retires the old layer and reconstructs the preview instead of reusing tokens whose old drawable might still appear.

普通预览只保留最新源帧；插帧额外保留一个前帧引用及一个固定待呈现端点，不积累采集队列。共享信号量限制 GPU 同时一帧在飞，独立呈现 token 限制尚未上屏的 drawable 最多三个。包括部分失败在内，会话、像素缓冲、纹理引用及 CI 任务都保活到 GPU 完成。跨设置改变仍保护生成、源帧及回退帧的呈现顺序。GPU 完成后呈现回调失联时退役旧图层并重建预览，不复用仍可能迟到的旧 drawable token。

Matching video-range 420v Rec.709 buffers can use a Metal plane resampling path without an RGB round trip. Other formats, ranges, color metadata or orientations retain explicit Core Image conversion. No third-party runtime or proprietary Lossless Scaling/GPL implementation is included.

符合视频范围 420v、Rec.709 元数据及正常方向的缓冲可使用 Metal 平面缩放，省去 RGB 往返转换；其他格式、范围、色彩及方向继续走显式 Core Image 转换。没有新增第三方运行依赖，也未复制小黄鸭或 GPL 实现。

The existing three-drawable layer pool can hold a prior source, midpoint and endpoint without raising GPU concurrency. A late endpoint may be rebased, but its received-time age plus future submission lead must remain within three of its original source periods; this is not a bound on physical screen latency. Compositor lateness is separated from inference overload. / 沿用三个 drawable 的图层池容纳上一原帧、中间帧与端点，不增加 GPU 并发。迟到端点可重新排期，但接收年龄加未来提交提前量不得超过创建时三个源帧周期；这不限制物理上屏延迟。呈现迟到与推理超载分别处理。

The spatial scaler caches at most two dimension pairs to avoid rebuilding resources for alternating source/midpoint sizes. Every entry is retained through GPU completion even after eviction. / 空间放大器最多缓存两组尺寸，避免原帧与中间帧交替时重建资源；即使淘汰也保活到 GPU 完成。

## Validation / 验证

- `./Scripts/test-metal-upscaler-lru.sh --gpu`: two-key reuse, eviction and evicted-resource readback under Metal validation.
- `./Scripts/test-frame-interpolation-policy.sh`: sizing/fractional rate/admission boundaries; no GPU claim.
- `./Scripts/test-capture-compatibility.sh`: legacy settings, bounded history, PTS cadence and reset boundaries.
- `./Scripts/test-frame-interpolator-gpu.sh`: native processor color/orientation/lifetime smoke under Metal validation.
- `./Scripts/test-preview-interpolation-display.sh`: synthetic input in a real window, ordering, actual generated presentations, three-drawable bound, minimize/restore and disable. `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60` enables strict actual-presentation throughput/spacing acceptance, not just a smoke pass. Optional `MONIVIEW_TEST_FPS`, `MONIVIEW_TEST_WIDTH`, `MONIVIEW_TEST_HEIGHT` vary synthetic input. `MONIVIEW_TEST_PRESENTATION_FAILURE=1` injects lost presentation callbacks.

Sustained 120 FPS has **not been certified**. Do not report the strict 120 test as PASS until the native-window run completes and its actual drawable-present callbacks satisfy cadence, spacing and deadline checks. GPU command duration, generated-frame counts, or successful processing alone are not presentation acceptance.

截至本次更新，持续 120 FPS **尚未认证**。只有原生窗口 strict 测试完成，并且实际 drawable 呈现回调满足节奏、间隔及 deadline 检查后，才能报告 PASS。GPU 命令耗时、生成帧数或处理调用成功都不等于上屏验收。

These tests do not certify another capture card, native 4K input, every Mac, sustained 120 FPS, gameplay artifacts, end-to-end latency, long-term memory behavior or iPad. Native hardware coverage and omissions belong in [LOCAL_VALIDATION.md](LOCAL_VALIDATION.md).

这些测试不认证其他采集卡、原生 4K 输入、所有 Mac、持续 120 FPS、游戏运动瑕疵、总延迟、长期内存趋势或 iPad；真机覆盖及缺口记录于 [LOCAL_VALIDATION.md](LOCAL_VALIDATION.md)。

## Future iPad boundary / 后续 iPad 边界

Sizing/admission policy and media timestamps are platform-neutral. Capture discovery, display-link/screen information, file dialogs, app lifecycle, permissions and UI remain platform adapters. An iPad implementation must query runtime processor support and its own current display cadence, not inherit this Mac's capabilities. This change adds no empty iPad target and claims no iPad acceptance.

尺寸／准入策略和媒体时间戳可共享；采集发现、显示回调／屏幕信息、文件对话框、生命周期、权限及 UI 仍需平台适配。iPad 必须查询自身运行时处理器能力和显示节奏，不能继承这台 Mac 的结果。本轮没有建立空壳 iPad target，也未声称已完成 iPad 验收。

The local SDK declares this processor for macOS 26 and iOS 26; runtime support still varies by device and configuration. The API's `numberOfInterpolatedFrames = x` provides `2^x - 1` available uniformly spaced interpolation points, not a direct multiplier. This implementation chooses only x=1, phase 0.5. A higher configuration increases latency; an isolated successful call at arbitrary phases does not certify evenly paced 3× output. / 本地 SDK 声明 macOS 26、iOS 26 可用，但仍需按设备及配置检查运行时支持。`numberOfInterpolatedFrames = x` 提供 `2^x - 1` 个均匀插值点，不是直接的倍率；本实现仅用 x=1、中点 0.5。更高配置会增加延迟，任意相位单次调用成功不代表均匀 3× 输出验收。

## Open-source alternatives / 开源参考

- [rife-ncnn-vulkan](https://github.com/nihui/rife-ncnn-vulkan): RIFE neural interpolation with macOS Vulkan/MoltenVK support; its code is [MIT](https://github.com/nihui/rife-ncnn-vulkan/blob/master/LICENSE). Worth studying motion estimation and GPU preprocessing, but adds a runtime/model and GPU interoperability work. Code, bundled models and dependencies need separate checks before distribution. No performance comparison with this app was run. / 可参考运动估计及 GPU 预处理；引入运行库、模型及 GPU 互操作成本，分发前分别核查，未做同条件性能对照。
- [sepconv-ios](https://github.com/carlo-/sepconv-ios): a Core ML plus Metal example. Code is MIT but models are academic-only and icons have separate terms; fixed sizes and memory limits are documented. Do not ship its models in a paid app without another license. / Core ML 与 Metal 分工参考；代码 MIT，但模型仅限学术、图标另有条款，并有固定尺寸和内存限制，不能直接随付费版发行模型。

Apple public processors remain the current dependency-free implementation choice, not a claim of universally best image quality. AI super-resolution estimates detail; interpolation estimates motion between frames. Neither reconstructs guaranteed original detail or eliminates the need for a later frame. / 当前继续用 Apple 公共处理器、保持无第三方运行依赖，不宣称普遍最佳画质。AI 超分估计细节，插帧估计帧间运动，都不保证还原原始细节或免去等待后帧。

## Apple sources / Apple 资料

- [Low-latency interpolation configuration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration)
- [WWDC25 machine-learning video effects](https://developer.apple.com/videos/play/wwdc2025/300/)
- [Metal drawable lifetime](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)

The displayed link frequency uses Apple's `1 / (targetTimestamp - timestamp)` period. It does not count callbacks skipped by the application or prove presented FPS. Strict throughput validation uses actual `presentedTime` callbacks separately. / 界面的链路频率按 Apple 报告的周期计算，不统计应用漏回调，也不是上屏帧率证明；严格吞吐验收另用实际 `presentedTime` 回调。
