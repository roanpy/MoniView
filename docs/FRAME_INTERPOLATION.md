# Optional preview frame interpolation / 可选预览插帧

## Contract / 行为边界

This feature is off by default and requires the public VideoToolbox low-latency frame processor on a supported macOS 26+ GPU. It generates one midpoint between two source frames: a **2× target**, not a guarantee that every midpoint reaches the screen. The info card reports source and generated frames from actual drawable-presented callbacks. Output FPS is their sum in a shared sampling window, including source-only fallback; redraws of the same source and retired-stream callbacks do not count. Capture FPS, recording and PNG export remain based on original source frames. Source quality, gameplay input latency and HDMI-to-screen latency are not improved merely by generating frames.

默认关闭，需要 macOS 26+ 和系统支持的 GPU。使用 Apple 公开 VideoToolbox 低延迟处理器生成两个原帧之间的一张中间帧：**目标为 2×，不保证每张生成帧都能呈现**。信息卡的原帧与生成帧数来自实际呈现回调；输出 FPS 使用同一取样窗口的两者总和，回退时仍显示原帧输出数，同一原帧重绘和旧流回调不重复计数。采集、录制和 PNG 导出仍以原始输入帧为基础；插帧不会凭空提高源画质或降低操作、HDMI 到屏幕的总延迟。

## Simple controls and override / 简单控制与强制模式

The multiplier selector offers Off / 2×. Quality is separate: Low (adaptive), Medium (up to 720p), High (up to 1080p). Existing persisted Smooth/Clear values still decode; Medium is the default when first enabling the new selector. Higher multipliers are not implemented and are not offered as working options.

倍率提供关闭／2×，质量单独提供低（自适应）、中（最高720p）、高（最高1080p）。旧流畅／清晰设置仍可读取；新倍率首次启用默认中档。未实现的更高倍率不作为可用选项展示。

Force interpolation attempts is off by default. It ignores measured performance admission and budget-driven quality reductions/cooldowns, but retains increasing stable PTS, runtime/size support, the screen's refresh limit, source freshness, presentation deadlines, single GPU command concurrency, bounded drawable ownership and GPU-error recovery. It is an attempt, not guaranteed FPS. Cost and actual generated/output counts remain visible. The override is stored as an optional field so older saved settings decode unchanged.

强制尝试默认关闭，忽略测得的性能预算准入以及预算触发的降档／冷却；仍保留稳定递增 PTS、系统／尺寸支持、屏幕刷新率上限、原帧时效、呈现期限、单 GPU 命令、drawable 有界保活和 GPU 错误恢复。它表示持续尝试，不保证帧数；负担与实际生成／输出继续显示。新增字段可选，兼容旧保存设置。

On a 60 Hz display, 30→60 is eligible; 45→90 and 50→100 are not. Force does not bypass this physical limit. Prefer native 60 capture if advertised, without silently changing the user's selected capture rate. Converting 45/50 to exactly 60 would require a separately validated variable-phase frame-rate conversion pipeline. Native 90/120 capture choices appear only when advertised for the selected resolution; they do not imply 180/240 interpolation support.

60 Hz 屏幕可准入30→60；45→90、50→100不可准入，强制开关也不绕过物理限制。采集卡上报原生60时可优先选择，但不自动改掉用户采集设置。45/50→精确60需要单独验证的可变相位转换。当前分辨率上报90/120才显示对应采集选择，不意味着插帧支持180/240。

The aligned quick capture-rate field shows at most four advertised canonical rates plus Auto, including 90/120 on suitable hardware; a selected canonical rate remains in the shortcuts. All advertised rates, including fractional rates and lower endpoints, remain in the dropdown.

对齐的采集快捷栏最多显示四个设备上报的常用帧率加自动，支持时包含90/120，并保留已选常用值；所有档位（含分数帧率及低端点）仍在下拉菜单。

## Independent dimensions / 三种尺寸分开

| Layer / 层级 | Policy / 规则 |
| --- | --- |
| Capture input / 采集输入 | Select actual device-advertised format and fractional FPS. A 4K HDMI specification is not proof of 4K USB capture. / 按设备上报格式及精确帧率选择；4K HDMI 规格不等于 4K USB 采集。 |
| Interpolation / 插帧 | Efficient starts with a 1280 long-edge cap, or 960 when input is above 40 FPS. Repeated P95 budget failures step its cap down through 1280→960→854. Preserve aspect ratio, round each dimension down to even, and never enlarge smaller input. Show the actual working dimensions. Medium stays capped at 1280 (720p landscape), High at 1920 (1080p landscape); neither is automatically downscaled. Force mode also disables budget-driven step-downs in Low. / 流畅档默认长边上限 1280；输入超过 40 FPS 时从 960 开始。P95 预算持续超限时依次降到 960→854（低帧率起始档还包括 1280→960）。保持比例、各边向下取偶数，不放大小输入，并显示当前实际工作尺寸。中档上限 1280（横屏720p），高档上限 1920（横屏1080p），两者不自动降低工作尺寸；强制模式也关闭低档因预算触发的降档。 |
| Spatial output / 显示放大 | Original, 1080p, 2K, 4K or Match Display. Targets are processing caps; low-latency mode limits them to the visible pixel size. / 原始、1080p、2K、4K 或匹配屏幕都是处理上限；低延迟模式限制到实际可见像素尺寸。 |

For example, 720p input can be interpolated at its original size and spatially enlarged to 1080p/2K/4K. 4K input can use a lower-resolution midpoint while retaining original 4K source endpoints. This can make alternating-frame detail differ: it is a deliberate resource/quality tradeoff, **not native 4K interpolation**. Unsupported dimensions, unstable cadence or excessive cost fall back to source frames. Portrait and non-16:9 sources retain aspect ratio.

例如，720p 输入可按原始尺寸插帧后放大到 1080p/2K/4K；4K 输入可生成较小尺寸的中间帧并保留原始 4K 端点。交替帧的细节可能不一致，这是资源与画质的取舍，**不是原生 4K 插帧**。系统不支持尺寸、输入节奏不稳定或处理过重时回退原帧；竖屏及非 16:9 输入保持比例。

## Refresh and cost / 刷新率与负担

Admission checks stable increasing media timestamps, the current window's screen limit and the system-reported display-link period. It does not infer refresh rate from a Mac model, GPU name, selected capture FPS or a display's marketing maximum. ProMotion is adaptive; a 120 Hz capable panel configured to fixed 60 Hz cannot display 120 FPS. Cross-screen/backing/visibility changes invalidate scheduling assumptions. A native Display Settings link lets the user change the OS setting; the app does not silently change global settings.

准入同时检查稳定递增的媒体时间戳、窗口所在显示器的当前上限和系统报告的显示链路周期；不依据 Mac 型号、GPU 名称、选定采集帧率或宣传值猜测。ProMotion 是自适应刷新，支持 120 Hz 的面板设为固定 60 Hz 时不能显示 120 FPS。跨屏、缩放及可见性改变会重置调度假设。提供系统显示器设置入口，由用户选择全局设置。

A 60 FPS source on a 120 Hz display has an 8.33 ms presentation slot; 30→60 has 16.67 ms. A midpoint may take up to 1.5 slots when encoded ahead of its presentation; the endpoint must fit within 90% of one slot. Their CPU-encode plus GPU-execution P95 sum must fit within 90% of the complete source-frame cycle. Actual presentation deadlines remain mandatory. The indicator shows that pair sum against the pair's admission budget (15 ms for 60→120; 30 ms for 30→60). The indicator uses up to 32 steady-state samples; two measured native-only startup warmups are separate. Overload triggers cooldown and, in Efficient mode only, adaptive working-size reduction. These are processing budgets, **not total system GPU utilization**; they exclude drawable acquisition/presentation delay, capture transport and HDMI latency. Other GPU work and output scaling can affect actual presentation.

60→120 的每个呈现时隙约 8.33 ms，30→60 约 16.67 ms。提前编码的中间帧允许最多占 1.5 个时隙，原帧端点须在一个时隙的 90% 内完成；两者 CPU 编码加 GPU 执行 P95 之和须在完整源帧周期的 90% 内完成，同时保留实际呈现期限检查。界面显示整对成本与准入预算：60→120 为 15 ms，30→60 为 30 ms。提示使用最多 32 个稳态样本；两次有实测成本的原帧校准预热单独处理。超限会冷却回退，只有流畅档会自适应降低工作尺寸。这些是处理预算，**不是整机 GPU 占用率**；不包含 drawable 获取及实际上屏延迟、采集传输或 HDMI 延迟。其他 GPU 工作和放大目标都会影响实际呈现。

Interpolation needs the current source before computing its midpoint, and delays its endpoint until after that midpoint. This adds capture-period/display-alignment latency even when inference is fast. Disable interpolation for the lowest interactive latency. Two cost tiers do not constitute a universal quality or performance certification.

必须收到当前源帧才能生成中间帧，随后再呈现端点，因此即便推理很快，也会增加采集周期与显示对齐相关的延迟。最低操作延迟应关闭插帧；两个档位不代表跨设备性能或画质认证。

## Composition and resource lifetime / 组合与资源生命周期

Color and sharpening apply once after midpoint generation. MetalFX/Lanczos spatial enlargement remains available for source endpoints and Clear midpoints. Smooth midpoints deliberately skip intermediate spatial scaling and use one inexpensive final resize to the visible area. The standalone AI super-resolution session is suspended while interpolation is selected; its preference is retained and the enhancement panel explains the pause. Apple also offers joint temporal/spatial interpolation, but that API restricts the joint path to 2× spatial scaling and one generated midpoint. It has not been enabled or certified here. Independent 3×/4× temporal processing requires separate presentation/budget/quality acceptance; successful one-shot processor calls are not throughput proof.

生成中间帧后只执行一次色彩及锐化，原帧端点和清晰档中间帧可继续使用 MetalFX/Lanczos 空间放大。流畅档中间帧跳过中间放大，只做一次较轻的最终窗口缩放。选择插帧期间暂停独立 AI 超分会话、保留原有选项，增强面板显示暂停说明。Apple 另有联合时间／空间处理接口，但联合路径仅支持 2× 空间放大及一张中间帧；当前未启用、未认证。独立 3×/4× 插帧还需分别验证呈现、负担与画质，单次处理成功不是实时性能证明。

Normal preview retains only the latest source. Interpolation additionally retains one preceding reference and one fixed pending endpoint, with no accumulating capture queue. A shared semaphore limits GPU submissions to one in flight, while presentation tokens separately cap future unpresented drawables at three. Completion resources retain sessions, pixel buffers, texture references and CI tasks through GPU completion, including partial failure. Presentation deadlines cover generated/source/fallback frames across setting changes. A lost presentation callback after GPU completion retires the old layer and reconstructs the preview instead of reusing tokens whose old drawable might still appear.

普通预览只保留最新源帧；插帧额外保留一个前帧引用及一个固定待呈现端点，不积累采集队列。共享信号量限制 GPU 同时一帧在飞，独立呈现 token 限制尚未上屏的 drawable 最多三个。包括部分失败在内，会话、像素缓冲、纹理引用及 CI 任务都保活到 GPU 完成。跨设置改变仍保护生成、源帧及回退帧的呈现顺序。GPU 完成后呈现回调失联时退役旧图层并重建预览，不复用仍可能迟到的旧 drawable token。

Matching video-range 420v Rec.709 buffers can use a Metal plane resampling path without an RGB round trip. Other formats, ranges, color metadata or orientations retain explicit Core Image conversion. No third-party runtime or proprietary Lossless Scaling/GPL implementation is included.

符合视频范围 420v、Rec.709 元数据及正常方向的缓冲可使用 Metal 平面缩放，省去 RGB 往返转换；其他格式、范围、色彩及方向继续走显式 Core Image 转换。没有新增第三方运行依赖，也未复制小黄鸭或 GPL 实现。

When Core Image conversion is necessary, Smooth uses fast affine input resampling instead of Lanczos; Clear retains Lanczos. This reduces work but may soften or alias fine moving details, even at the 854-pixel adaptive floor. Metadata is never invented to force the direct path. The general enhancement badge reports the source spatial pipeline; actual temporal dimensions and presentation counts remain separate. / 需要 Core Image 转换时，流畅档采用较轻的仿射输入缩放，清晰档保留 Lanczos。较小工作尺寸可能使运动细节模糊或产生锯齿，尤其是在较小的处理尺寸下；不会编造元数据强制走直接路径。增强标签稳定报告原帧空间处理链路，实际插帧尺寸和呈现计数另列。

The existing three-drawable layer pool can hold a prior source, midpoint and endpoint without raising GPU concurrency. A late endpoint may be rebased, but its received-time age plus future submission lead must remain within three of its original source periods; this is not a bound on physical screen latency. Compositor lateness is separated from inference overload. / 沿用三个 drawable 的图层池容纳上一原帧、中间帧与端点，不增加 GPU 并发。迟到端点可重新排期，但接收年龄加未来提交提前量不得超过创建时三个源帧周期；这不限制物理上屏延迟。呈现迟到与推理超载分别处理。

The spatial scaler caches at most two dimension pairs to avoid rebuilding resources for alternating source/midpoint sizes. Every entry is retained through GPU completion even after eviction. / 空间放大器最多缓存两组尺寸，避免原帧与中间帧交替时重建资源；即使淘汰也保活到 GPU 完成。

## Validation / 验证

- `./Scripts/test-metal-upscaler-lru.sh --gpu`: two-key reuse, eviction and evicted-resource readback under Metal validation.
- `./Scripts/test-frame-interpolation-policy.sh`: sizing/fractional rate/admission boundaries; no GPU claim.
- `./Scripts/test-capture-compatibility.sh`: legacy settings, bounded history, PTS cadence and reset boundaries.
- `./Scripts/test-frame-interpolator-gpu.sh`: native processor color/orientation/lifetime smoke under Metal validation.
- `./Scripts/test-joint-interpolation-gpu.sh`: compile-only by default. Explicit `--gpu` probes Apple's joint 2× spatial / one-midpoint path; `--async-diagnostic` checks one pair through the error-reporting asynchronous API, with no GPU timing or presentation claim. `MONIVIEW_JOINT_CASES=960` selects a source width. This is an isolated, currently failing experiment, not a production feature or required passing regression. See the dated validation record. / 联合接口默认仅编译，显式参数才运行；异步单次诊断不计 GPU 吞吐。当前是未通过的隔离实验，不是已启用产品功能。
- `./Scripts/test-preview-interpolation-display.sh`: synthetic input in a real window, ordering, actual generated presentations, three-drawable bound, minimize/restore and disable. `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60` enables strict actual-presentation throughput/spacing acceptance, not just a smoke pass. Optional `MONIVIEW_TEST_FPS`, `MONIVIEW_TEST_WIDTH`, `MONIVIEW_TEST_HEIGHT` vary synthetic input. `MONIVIEW_TEST_METADATA=missing` exercises the Core Image fallback. `MONIVIEW_TEST_PRESENTATION_FAILURE=1` injects lost presentation callbacks.

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

## Joint AI path next steps / 联合 AI 路径后续

Apple's public API permits resolution and frame-rate enhancement together; they are not inherently incompatible. The current standalone neural scaler is paused to limit work, not because the technologies cannot coexist. Before enabling the joint path, resolve the local processor-initialization failure, verify both source/midpoint outputs, and integrate their lifetimes and presentation deadlines into the existing single-command policy. Then compare actual presented cadence, motion detail and cost against the current fallback at the same input/display/settings. Examples such as 720p60→1440p120 or 1080p60→4K120 are dimensional possibilities, **not measured promises**. / 两者可以组合；独立模型暂停是负担控制。联合路径先解决本机处理器初始化失败、核实两张输出，再接入已有保活、单命令与呈现规则；之后同条件对比真实呈现、运动细节和成本。720p60→1440p120、1080p60→4K120 仅是尺寸关系，不是性能承诺。

## Alternative-engine evaluation / 替代引擎评估

[Practical-RIFE](https://github.com/hzwer/Practical-RIFE) separates frame-rate multiplier from optical-flow processing scale and offers lower-cost lite models. [RIFE](https://github.com/hzwer/ECCV2022-RIFE) documents arbitrary-time interpolation. These are useful design references, not Apple throughput measurements. A Core ML/Metal prototype could test 2× and variable phases at 720p/1080p using identical input sequences, display size, actual presentation counts, P95 total cost, artifacts and added latency. Do not ship a model or third-party runtime until its license, conversion and measured benefit are verified; no such backend was added by this change. Flowframes and Stellaria code were not copied.

可参考倍率与光流工作尺寸分离、lite模型和任意时间插值，但开源说明不等于苹果端实测。后续 Core ML/Metal 原型应在同一输入、显示尺寸下比较2×／可变相位、真实上屏计数、P95总处理、瑕疵和新增延迟。模型许可、转换及收益确认前不随产品分发；本批没有新增第三方后端，也未复制 Flowframes 或 Stellaria 的代码。

## Capture versus content cadence / 采集与内容节奏

Selecting 30 FPS configures the UVC stream accepted by the Mac; it does not change the console or source computer's output/game rate. The app reports delivered frame timestamps, not HDMI source telemetry. A 60 FPS stream may carry repeated 30 FPS content, a static scene, menus, or device repeats. Brand names cannot establish any of these. Preserve original PTS and capture/recording cadence.

选30 FPS配置Mac收到的UVC流，不会改变主机／电脑的HDMI输出或游戏帧率。界面采集帧率来自收到的时间戳，不是HDMI源遥测。60流可能承载重复的30内容、静止画面、菜单或设备重复输出，不能依据品牌区分。应保留原始PTS、采集和录制节奏。

Optional exact-duplicate interpolation skipping compares all active pixels (not padding or a sparse thumbnail) and relevant image metadata on supported 420v/420f/BGRA buffers. Identical pairs skip midpoint inference while preserving their original endpoints. It defaults off, never labels the result game FPS, and does not silently change the capture rate or interpolate between non-adjacent references. Noisy/compressed near-duplicates remain distinct deliberately. Diagnostics count skipped inference pairs, not the stream's unique-content FPS. Sampling, scene-cut detection, arbitrary-phase rate conversion and automatic content-cadence adaptation need separate motion/latency acceptance before being enabled.

可选的完全重复检测比较420v/420f/BGRA全部有效像素及相关图像信息，不比较padding、不凭缩略图。相同的两帧仅跳过中点推理，原始端点继续显示。默认关闭，不标作游戏FPS、不自动改变采集档位、不把不相邻参考帧混入当前时序。带噪／压缩的近似重复仍作为不同画面。诊断计数是跳过的推理对，不是整条流的内容更新帧率。采样去重、场景切换检测、可变相位转换及自动内容节奏适配须另做运动与延迟验收。

Presented interval P95 uses actual positive drawable presented times for unique source presentations and generated frames, with a bounded 120-interval history. Same-source redraws and retired-stream callbacks do not contribute. Hidden previews reset the interval baseline and report presentation paused; neither invisible-window zero FPS nor callback/GPU timing is HDMI latency. Averages such as 80–90 FPS alone cannot prove even frame pacing.

呈现间隔P95按唯一原帧及生成帧的实际正值presentedTime计算，最多保留120个间隔；同帧重绘与旧流回调排除。不可见时清空间隔基线并报告暂停呈现。不可见的0 FPS、回调／GPU耗时都不是HDMI总延迟；80～90平均FPS本身不能证明均匀帧间隔。

### Priorities after this baseline / 后续优先级

1. Keep the window genuinely visible and measure actual presentation intervals, source retention, missed endpoints and P95 costs under fixed input/settings. Do not use invisible-window zero FPS as a throughput sample. Prefer stable original 60 to an uneven forced 80–90.
2. Validate motion-aware duplicate/content-cadence and scene-cut handling independently before retiming. Exact duplicate skipping is a safe cost optimization, not inferred game telemetry.
3. Prototype arbitrary-phase interpolation for 45/50→60 and 3× only after an engine actually supplies the required phases. Reuse existing bounded buffer ownership; no unbounded frame queue.
4. Compare Apple's temporal processor with a license-verified lite RIFE Core ML/Metal prototype at identical input, output size and actual cadence. Ship a replacement only if quality and end-to-end cost beat the current path. Lossless Scaling's Windows/DirectX model and its Linux community ports are design references, not a macOS backend available to this app. See its [official requirements](https://store.steampowered.com/app/993090/Lossless_Scaling_2/).

先做固定输入／设置下可见窗口的真实间隔与端点验收，宁可稳定原生60也不承诺强制80～90更顺滑；重复内容／切场景先独立验证，再重排时间线；可变相位及3×必须由引擎真正提供；RIFE轻量原型需核实许可并同条件对照，不能把小黄鸭Windows／Linux能力当作本程序Mac后端。

### Source references for duplicate policy / 去重策略来源

- [FFmpeg mpdecimate](https://ffmpeg.org/ffmpeg-filters.html#mpdecimate): approximate block-difference thresholds; reviewed as behavior only, no GPL code copied.
- [FFmpeg scene detection](https://ffmpeg.org/ffmpeg-filters.html#scdet): scene changes are a separate problem from exact duplicates.
- [mpv interpolation/display sync](https://mpv.io/manual/master/#options-interpolation): display pacing is distinct from source cadence.
- [Apple pixel-buffer lock](https://developer.apple.com/documentation/corevideo/cvpixelbufferlockbaseaddress(_:_:)) and [row-stride guidance](https://developer.apple.com/library/archive/qa/qa1829/_index.html): CPU access locks and per-row stride handling.

The implementation here is independently written with exact active-byte comparisons, default disabled; it introduces no borrowed GPL runtime. Repeated source pictures retain their original timestamps and source presentation. Precise duplicates and static scenes are deliberately not labelled as a lower game FPS.

### What the input can tell us / 输入监测边界

The current app accepts AVFoundation video devices. Device-advertised modes and sample PTS describe the stream delivered to the Mac, not the console's internal game rendering FPS. Exact repeats can also be static content; noisy repeats may differ. Selecting 30 FPS limits the capture stream and does not remotely set the console's HDMI output. This app has no EDID control, HDMI source telemetry or game process integration.

当前只接入 AVFoundation 视频设备。设备上报格式与收到的时间戳描述 Mac 收到的流，不能确认游戏内部渲染帧率。相同画面也可能来自静止场景；重复画面经过压缩或噪声后也可能不完全相同。选择 30 FPS 限制采集流，不会远程改变主机 HDMI 输出。本程序没有 EDID 控制、HDMI 源遥测或游戏进程接口。

A console connected directly to an ordinary Mac HDMI output cannot be captured through that output. Receiving another machine's video still needs capture hardware or a separate supported transport. Capturing games running on this same Mac through ScreenCaptureKit is a possible separate input backend, but is **not implemented** in this release. ScreenCaptureKit's requested capture interval would still not certify a game's own render FPS.

普通 Mac HDMI 输出口不能作为主机视频输入；其他机器的画面仍需采集硬件或另外支持的传输方案。本机游戏可考虑单独实现 ScreenCaptureKit 输入，但本版**未实现**，其采集间隔也不能认证游戏内部帧率。

References: [AVFoundation capture frame duration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration), [ScreenCaptureKit capture interval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval).

### Compact controls / 紧凑面板

The primary enhancement panel keeps scaling, multiplier, quality and measured output together. Force and exact-duplicate skipping are under More options; long explanations are tooltips. Budget percentage is processing cost against the interpolation admission budget, not whole-system GPU usage. The panel is height-bounded and scrolls in small windows; detailed sizes and pacing remain in Video Info. / 主面板保留放大、倍率、质量与实测输出；强制和完全重复检测收进更多选项，长说明改成帮助提示。预算百分比不是整机 GPU 占用率；面板限制高度，小窗口可滚动，详细尺寸与呈现节奏在画面信息中。
