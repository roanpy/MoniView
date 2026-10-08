# Optional preview frame interpolation / 可选预览插帧

## Contract / 行为边界

Interpolation is off until the user enables it. The public VideoToolbox path requires a supported macOS 26+ GPU and generates one midpoint; Flow Beta uses the app’s Metal engine and supports 2× or 3×. These are targets, not guarantees that every generated frame reaches the screen. The info card reports source and generated frames from actual drawable-presented callbacks. Output FPS is their sum in a shared sampling window, including source-only fallback; redraws of the same source and retired-stream callbacks do not count. Capture FPS, recording and PNG export remain based on original source frames. Source quality, gameplay input latency and HDMI-to-screen latency are not improved merely by generating frames.

插帧初始关闭。Apple 公开 VideoToolbox 路径需要 macOS 26+ 和系统支持的 GPU、每对补一张；自研 Metal 光流 Beta 支持 2× 或 3×。**倍率是目标，不保证每张生成帧都能呈现**。信息卡的原帧与生成帧数来自实际呈现回调；输出 FPS 使用同一取样窗口的两者总和，回退时仍显示原帧输出数，同一原帧重绘和旧流回调不重复计数。采集、录制和 PNG 导出仍以原始输入帧为基础；插帧不会凭空提高源画质或降低操作、HDMI 到屏幕的总延迟。

## Simple controls and override / 简单控制与强制模式

Interpolation is a switch, not a multiplier choice: the renderer picks the smallest step that lifts the measured content rate to 60 FPS within the panel refresh limit. 30 FPS content on a 60 Hz or 120 Hz panel therefore stays on the single-midpoint 2× path, which is the cheap and correct choice. The flow-blend tier can also generate a second midpoint (phases 1/3 and 2/3) for content below 25 FPS, where doubling cannot reach 60; the VideoToolbox processor produces only the midpoint and stays on 2×. Quality is separate: Low (adaptive), Medium (up to 720p), High (up to 1080p), Flow Beta. Existing persisted Smooth/Clear values still decode. The 20→60 three-phase path passed synthetic native-window presentation and restart checks on the local host; real-game motion quality remains separately unaccepted.

Flow Beta is a fourth quality tier using the app's own Metal optical-flow blend engine instead of the VideoToolbox processor: sparse bidirectional block matching over a three-level luma pyramid with a confidence gate, where ambiguous pixels fall back to cross-dissolve. On this M5 Max the 1280×720 fixture measures about 0.7 ms GPU median with an idle GPU and roughly 1–7 ms while the preview itself loads the GPU, versus 15–22 ms for the VT processor at the same size; the same admission, budget and deadline machinery still applies, so a busy GPU backs off to source frames exactly as with other tiers. Above 40 FPS input the working size starts at a 1280 long edge. The UI checks Metal capability independently of VideoToolbox; unavailable VT presets fall back to an available engine. Expect softer motion boundaries and dissolve fallbacks on flat, repeated, occluded or cut content; it is a beta for real-motion acceptance, not a quality promise.

插帧是开关而非倍率选择：渲染器按实测内容帧率，在屏幕刷新率允许范围内选择能把它提升到 60 FPS 的最小步长。30 FPS 内容在 60/120 Hz 屏上因此维持单中点的 2× 路径，这是最经济且正确的选择。光流档还可为低于 25 FPS 的内容生成第二个中点（相位 1/3 与 2/3），那种情况 2× 到不了 60；VideoToolbox 处理器仅产出中点，固定 2×。质量单独提供低（自适应）、中（最高720p）、高（最高1080p）、光流 Beta；旧流畅／清晰设置仍可读取。20→60 的三相位路径已通过本机合成源原生窗口呈现与重启检查；真实游戏运动画质仍需单独验收。

光流 Beta 是第四个质量档，使用应用自研 Metal 光流混合引擎而非 VideoToolbox 处理器：三级亮度金字塔上的稀疏双向块匹配加置信度门控，不确定像素回退为交叉淡化。本台 M5 Max 的 1280×720 夹具实测：GPU 空闲时中位约 0.7 ms，预览自身占用 GPU 时约 1–7 ms；同尺寸 VT 处理器为 15–22 ms。准入、预算和呈现期限机制不变，GPU 繁忙时与其他档一样回退原帧。输入超过 40 FPS 时工作尺寸从长边 1280 开始。界面独立检测 Metal 能力，不再依赖 VideoToolbox 门槛；不可用的 VT 预设回退到可用引擎。平坦、重复纹理、遮挡或切场景处可能出现运动边缘变软与淡化回退；本档为实机运动画质验收的 Beta，不是画质承诺。

Enabling the interpolation master switch sets force attempts on. The Smoothness and Quality presets enable both; the user can turn force off explicitly afterwards. Force bypasses measured admission. Successful over-budget processing no longer reduces source-frame spatial scaling: the selected target and existing low-latency viewport bound are preserved. Low can reduce inference resolution; High/Medium keep their advertised midpoint limits. When no permitted inference reduction remains, Force continues deadline-safe attempts using the existing measurements instead of entering a two-second budget cooldown and repeated calibration. GPU failures still enter recovery cooldown. Increasing stable PTS, runtime/size support, the screen's refresh limit, source freshness, presentation deadlines, single GPU command concurrency and bounded drawable ownership remain mandatory. Cost and actual generated/output counts remain visible; Force does not guarantee FPS. The override is optional so older saved settings decode unchanged.

开启插帧总开关时默认开启强制尝试，流畅与画质预设同时开启两者；用户可主动关闭强制。强制绕过实测预算准入。成功处理超预算不再降低原始帧的空间放大：所选目标和既有低延迟可见区域限制保持生效；低档可降低推理尺寸，中高档保留各自中间帧上限。没有允许的推理降档时，强制保留测量结果并持续尝试满足期限的帧对，不再进入两秒预算暂停和反复预热；GPU失败仍进入恢复冷却。稳定递增PTS、系统与尺寸支持、屏幕刷新率、原帧时效、呈现期限、单GPU命令和drawable有界保活仍是必要条件。负担与实际生成、输出继续显示，强制不保证帧数；字段可选，兼容旧保存设置。

On a 60 Hz display, 30→60 is eligible; 45→90 and 50→100 are not. Force does not bypass this physical limit. Prefer native 60 capture if advertised, without silently changing the user's selected capture rate. Converting 45/50 to exactly 60 would require a separately validated variable-phase frame-rate conversion pipeline. Native 90/120 capture choices appear only when advertised for the selected resolution; they do not imply 180/240 interpolation support.

60 Hz 屏幕可准入30→60；45→90、50→100不可准入，强制开关也不绕过物理限制。采集卡上报原生60时可优先选择，但不自动改掉用户采集设置。45/50→精确60需要单独验证的可变相位转换。当前分辨率上报90/120才显示对应采集选择，不意味着插帧支持180/240。

The aligned quick capture-rate field shows up to four supported shortcuts plus Auto, including 90/120 on suitable hardware; the selected supported rate remains in the shortcuts; fractional labels use three slots to leave room for the measured-content reading. All advertised rates, including fractional rates and lower endpoints, remain in the dropdown.

对齐的采集快捷栏显示最多四个受支持的快捷帧率加自动，支持时包含90/120，并保留当前受支持的选择；小数标签时显示三个快捷档，给实测读数留空间；所有档位（含分数帧率及低端点）仍在下拉菜单。

## Enhancement presets / 增强预设

| Preset / 预设 | Strength / 强度 | Target / 放大目标 | Interpolation / 插帧 |
| --- | --- | --- | --- |
| Smooth / 流畅优先 | 0.55 | Source resolution / 原始输入 | Enables Flow Beta with force and Follow / 开启光流档及强制、跟随 |
| Quality / 画质优先 | 0.80 | Display backing size / 匹配屏幕 | Enables the available quality engine with force and Follow / 开启可用高质量档及强制、跟随 |
| Native enhancement / 原生增强 | 1.00 | Display backing size / 匹配屏幕 | Off; remembers the engine for later enable / 关闭，保留引擎供再次开启 |

Native enhancement keeps source frames, enables enhancement and removes the low-latency visible-size cap so the default target uses the current display's backing size even in a smaller window. It does not mean native input resolution. Strength 1.00 is sharpening/enhancement strength, not an upscaling multiplier. Previously saved manual values are unchanged until the user chooses a preset. Choosing Smoothness or Quality after Native enables interpolation for that preset's engine.

原生增强指保持原始帧率、关闭插帧，默认按当前屏幕绘制像素尺寸放大；不是保持采集分辨率。1.00 是增强强度而非放大倍率。旧保存的手动值不被新默认值覆盖；再次选择预设时才应用新组合。从原生增强切回流畅或画质会重新开启插帧；没有可用引擎时保持关闭并显示插帧不可用。

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

A 60 FPS source on a 120 Hz display has an 8.33 ms presentation slot; 30→60 has 16.67 ms. A midpoint may take up to 1.5 slots when encoded ahead of its presentation; the endpoint must fit within 90% of one slot. Each command's cost is the larger of CPU-encode plus GPU timestamp duration, or elapsed time from encode start to the GPU-completion callback. The latter captures processor/queue waits that GPU timestamps can omit; the two values are **not added together**. The midpoint and endpoint P95 cost sum must fit within 90% of the complete source-frame cycle. Actual presentation deadlines remain mandatory. The indicator shows that pair sum against the pair's admission budget (15 ms for 60→120; 30 ms for 30→60), using up to 32 steady-state samples; two hidden midpoint-calibration warmups are separate. Overload triggers cooldown and, in Efficient mode only, adaptive working-size reduction. These are processing budgets, **not total system GPU utilization**. They exclude drawable acquisition, actual presentation, main-thread completion bookkeeping, capture transport and HDMI latency, so they are not complete renderer-slot occupancy either. Other GPU work and output scaling can affect actual presentation.

60→120 的每个呈现时隙约 8.33 ms，30→60 约 16.67 ms。提前编码的中间帧允许最多占 1.5 个时隙，原帧端点须在一个时隙的 90% 内完成。每条命令取“CPU 编码＋GPU 时间戳耗时”和“编码开始至 GPU 完成回调的经过时间”中较大值，包含 GPU 时间戳可能遗漏的处理器／排队等待，**不会把两者再相加**。中间帧与端点 P95 成本之和须在完整源帧周期的 90% 内完成，同时保留实际呈现期限检查。界面显示整对成本与准入预算：60→120 为 15 ms，30→60 为 30 ms，使用最多 32 个稳态样本；两次隐藏中间帧校准预热单独处理。超限会冷却回退，只有流畅档会自适应降低工作尺寸。这些是处理预算，**不是整机 GPU 占用率**；不包含 drawable 获取、实际上屏、主线程完成记账、采集传输或 HDMI 延迟，也不等于完整渲染槽占用时间。其他 GPU 工作和放大目标都会影响实际呈现。

Interpolation needs the current source before computing its midpoint, and delays its endpoint until after that midpoint. This adds capture-period/display-alignment latency even when inference is fast. Disable interpolation for the lowest interactive latency. Two cost tiers do not constitute a universal quality or performance certification.

必须收到当前源帧才能生成中间帧，随后再呈现端点，因此即便推理很快，也会增加采集周期与显示对齐相关的延迟。最低操作延迟应关闭插帧；两个档位不代表跨设备性能或画质认证。

## Composition and resource lifetime / 组合与资源生命周期

Color applies once after midpoint generation. Every tier except Low runs a generated midpoint through the same spatial enlargement as its neighbouring source frames, so consecutive presented frames share one scaling quality; only Low keeps the cheaper inference-size midpoint with a single final resize. Sharpening is applied after the final fit, at display resolution, because a shrunk frame averages away acutance added before the resize. Measured on the M5 Max with a 1080p source at Match Display, the extra midpoint pass costs about a millisecond per pair. The standalone AI super-resolution session is suspended while interpolation is selected; its preference is retained and the enhancement panel explains the pause. Apple also offers joint temporal/spatial interpolation, but that API restricts the joint path to 2× spatial scaling and one generated midpoint. It has not been enabled or certified here. Independent 3×/4× temporal processing requires separate presentation/budget/quality acceptance; successful one-shot processor calls are not throughput proof.

生成中间帧后只执行一次色彩处理；除低档外，中间帧与原帧端点使用同一套空间放大，使相邻上屏帧的放大质量一致，低档仍保留推理尺寸加一次轻量最终缩放。锐化改在最终适配之后、按显示分辨率执行，否则缩小窗口会把先前加上的锐度平均掉。本机 M5 Max、1080p 源、匹配屏幕实测：多出的中间帧放大每帧对约 1 毫秒。选择插帧期间暂停独立 AI 超分会话、保留原有选项，增强面板显示暂停说明。Apple 另有联合时间／空间处理接口，但联合路径仅支持 2× 空间放大及一张中间帧；当前未启用、未认证。独立 3×/4× 插帧还需分别验证呈现、负担与画质，单次处理成功不是实时性能证明。

Normal preview retains only the latest source. Interpolation additionally retains one preceding reference and one fixed pending endpoint, with no accumulating capture queue. A shared semaphore limits GPU submissions to one in flight, while presentation tokens separately cap future unpresented drawables at three. Completion resources retain sessions, pixel buffers, texture references and CI tasks through GPU completion, including partial failure. Presentation deadlines cover generated/source/fallback frames across setting changes. A lost presentation callback after GPU completion retires the old layer and reconstructs the preview instead of reusing tokens whose old drawable might still appear.

普通预览只保留最新源帧；插帧额外保留一个前帧引用及一个固定待呈现端点，不积累采集队列。共享信号量限制 GPU 同时一帧在飞，独立呈现 token 限制尚未上屏的 drawable 最多三个。包括部分失败在内，会话、像素缓冲、纹理引用及 CI 任务都保活到 GPU 完成。跨设置改变仍保护生成、源帧及回退帧的呈现顺序。GPU 完成后呈现回调失联时退役旧图层并重建预览，不复用仍可能迟到的旧 drawable token。

Matching video-range 420v Rec.709 buffers with an explicit Center top-field chroma location and normal orientation can use Metal plane resampling without an RGB round trip. If a bottom-field location exists, it must also be Center. Missing chroma metadata is not assumed to mean Center. At the processor's native working size, an IOSurface buffer that satisfies every known source attribute can be retained directly without two source copies. Unknown SDK requirements, formats, ranges, metadata or orientations retain explicit conversion. No third-party runtime or proprietary Lossless Scaling/GPL implementation is included.

符合视频范围 420v、Rec.709、明确的 top-field Center 色度位置及正常方向的缓冲可使用 Metal 平面缩放；bottom-field 附件存在时也须为 Center，缺失附件不假定为 Center。同尺寸且满足全部已知处理器源属性的 IOSurface 输入可直接保活使用，省去两次源帧拷贝；未知 SDK 属性、格式、范围、元数据及方向走显式转换。没有新增第三方运行依赖，也未复制小黄鸭或 GPL 实现。

When Core Image conversion is necessary, Smooth uses fast affine input resampling instead of Lanczos; Clear retains Lanczos. This reduces work but may soften or alias fine moving details, even at the 854-pixel adaptive floor. Metadata is never invented to force the direct path. The general enhancement badge reports the source spatial pipeline; actual temporal dimensions and presentation counts remain separate. / 需要 Core Image 转换时，流畅档采用较轻的仿射输入缩放，清晰档保留 Lanczos。较小工作尺寸可能使运动细节模糊或产生锯齿，尤其是在较小的处理尺寸下；不会编造元数据强制走直接路径。增强标签稳定报告原帧空间处理链路，实际插帧尺寸和呈现计数另列。

The existing three-drawable layer pool can hold a prior source, midpoint and endpoint without raising GPU concurrency. A late endpoint may be rebased, but its received-time age plus future submission lead must remain within three of its original source periods; this is not a bound on physical screen latency. Compositor lateness is separated from inference overload. / 沿用三个 drawable 的图层池容纳上一原帧、中间帧与端点，不增加 GPU 并发。迟到端点可重新排期，但接收年龄加未来提交提前量不得超过创建时三个源帧周期；这不限制物理上屏延迟。呈现迟到与推理超载分别处理。

The spatial scaler caches at most two dimension pairs to avoid rebuilding resources for alternating source/midpoint sizes. Every entry is retained through GPU completion even after eviction. / 空间放大器最多缓存两组尺寸，避免原帧与中间帧交替时重建资源；即使淘汰也保活到 GPU 完成。

## Validation / 验证

- `./Scripts/test-metal-upscaler-lru.sh --gpu`: two-key reuse, eviction and evicted-resource readback under Metal validation.
- `./Scripts/test-frame-interpolation-policy.sh`: sizing/fractional rate/admission boundaries; no GPU claim.
- `./Scripts/test-capture-compatibility.sh`: legacy settings, bounded history, PTS cadence and reset boundaries.
- `./Scripts/test-frame-interpolator-gpu.sh`: native processor color/orientation/lifetime smoke under Metal validation.
- `./Scripts/test-interpolation-spatial-gpu.sh --gpu`: optimized offscreen VideoToolbox midpoint → MetalFX → final-texture checks with adjacent synthetic 720p/1080p/4K inputs, known color/orientation references and separate CPU/GPU/completion-interval measurements. Default is compile-only. `MONIVIEW_TEST_CASE='1080 high'` selects matching cases; `MONIVIEW_TEST_FORCE_INPUT_COPY=1` compares the previous copy path in test builds only. This does not measure actual presentations or certify native 4K capture. / 默认仅编译，显式运行才做离屏合成输入兼容性检查，不认证真机 4K 或上屏帧率。
- `./Scripts/test-joint-interpolation-gpu.sh`: compile-only by default. Explicit `--gpu` probes Apple's joint 2× spatial / one-midpoint path; `--async-diagnostic` checks one pair through the error-reporting asynchronous API, with no GPU timing or presentation claim. `MONIVIEW_JOINT_CASES=960` selects a source width. This is an isolated, currently failing experiment, not a production feature or required passing regression. See the dated validation record. / 联合接口默认仅编译，显式参数才运行；异步单次诊断不计 GPU 吞吐。当前是未通过的隔离实验，不是已启用产品功能。
- `./Scripts/test-preview-interpolation-display.sh`: synthetic input in a real window, ordering, actual generated presentations, three-drawable bound, minimize/restore and disable. `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60` enables strict actual-presentation throughput/spacing acceptance, not just a smoke pass. Optional `MONIVIEW_TEST_FPS`, `MONIVIEW_TEST_WIDTH`, `MONIVIEW_TEST_HEIGHT` vary synthetic input. `MONIVIEW_TEST_METADATA=missing` exercises the Core Image fallback. `MONIVIEW_TEST_PRESENTATION_FAILURE=1` injects lost presentation callbacks.

A controlled synthetic 1080p60 / Low / Force / MetalFX 2K native-window run passed the strict 60→120 gate on the local M5 Max, including a repeat after chroma validation was tightened. This is a specific synthetic-window result, **not certification of real UVC/gameplay at 120 FPS**, every quality tier or screen size. See the dated [local validation record](LOCAL_VALIDATION.md). GPU command duration, generated-frame counts, or successful processing alone are not presentation acceptance. Occlusion or a screen that reports less than 120 Hz causes the strict fixture to exit 2 (SKIP), not PASS.

本机 M5 Max 的合成 1080p60／低档／强制／MetalFX 2K 原生窗口已通过严格 60→120 测试，收紧色度位置检查后复测也通过。**不代表真实 UVC／游戏画面稳定 120 FPS，也不认证所有质量档位及窗口尺寸**，详见带日期的本地验收记录。GPU 耗时、生成数或处理调用成功不能代替上屏验收；遮挡或当前屏幕报告低于 120 Hz 时严格测试返回 SKIP（exit 2），不是 PASS。

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

RIFE upstream code uses MIT; the exact selected model-weight artifact requires separate terms verification. No RIFE weights are bundled. A local MLX evaluation of a RIFE-style model on this M5 Max measured roughly 168 ms at 854×480 and 260 ms at 720p per pair — far above the 33 ms slot of 30→60, let alone 8.3 ms at 60→120 — so the Core ML/MLX route stays shelved until a converted model demonstrably fits the slot on the target machine. The shipped Flow Beta tier instead follows the Lossless-Scaling-style design: a small fixed-cost Metal flow pipeline with no model weights and no third-party runtime. Flowframes and Stellaria code were not copied.

可参考倍率与光流工作尺寸分离、lite模型和任意时间插值，但开源说明不等于苹果端实测。RIFE 上游代码采用 MIT；具体选用权重的条款仍需单独核实，产品未随附 RIFE 权重。本机 MLX 评估在 M5 Max 上测得 854×480 约 168 ms、720p 约 260 ms 每对，远高于 30→60 的 33 ms 时隙，更远于 60→120 的 8.3 ms，因此 Core ML/MLX 路线在转换模型实测进入时隙前继续搁置。随附的光流 Beta 档采用小黄鸭式固定成本 Metal 光流设计：无模型权重、无第三方运行时。模型许可、转换及收益确认前不随产品分发；未复制 Flowframes 或 Stellaria 的代码。

## Capture versus content cadence / 采集与内容节奏

Selecting 30 FPS configures the UVC stream accepted by the Mac; it does not change the console or source computer's output/game rate. The app reports delivered frame timestamps, not HDMI source telemetry. A 60 FPS stream may carry repeated 30 FPS content, a static scene, menus, or device repeats. Brand names cannot establish any of these. Preserve original PTS and capture/recording cadence.

选30 FPS配置Mac收到的UVC流，不会改变主机／电脑的HDMI输出或游戏帧率。界面采集帧率来自收到的时间戳，不是HDMI源遥测。60流可能承载重复的30内容、静止画面、菜单或设备重复输出，不能依据品牌区分。应保留原始PTS、采集和录制节奏。

Content cadence is measured on a bounded serial input observer, independently of drawing and interpolation switches. It compares original buffers and PTS, rejects gaps or changed epochs, and expires stale estimates. Static content cannot establish game-engine FPS. Tolerant comparison estimates content updates; only exact evidence skips a picture. A window-edge overshoot is capped by the measured signal rate.

内容节奏由有界输入队列测量，与绘制负载、插帧开关独立；使用原始缓冲与 PTS，缺帧、代际切换和过期读数不作为当前证据。静止画面不能确定游戏引擎帧率。宽容比较用于估计，严格重复证据才跳过画面；估计不得超出测得的采样率。

Follow is now the interpolation basis switch, using the same persisted choice as duplicate skipping. It defaults on when no explicit choice exists. On: pair distinct content timestamps; off: pair capture timestamps. Neither setting changes hardware capture FPS. Keep 60 FPS capture to observe content changing from 30 back to 60. Flow/quality presets enable interpolation, force and Follow; Native enhancement explicitly turns interpolation off. The HUD reports the actual pair basis used by the renderer separately from the estimated content reading.

“跟随内容帧率”与跳过重复画面共用同一个状态；没有明确保存选择时默认开启。开启按不同内容画面的 PTS 配对，关闭按采集 PTS 配对，两者都不更改硬件采集档位。保留 60 帧采集才能观察内容从 30 恢复到 60。流畅／画质预设开启插帧、强制与跟随，原生增强明确关闭插帧；HUD 的实际配对依据与内容估计分开统计。

Integer 3× is selected automatically when appropriate. It does not implement constant 60 FPS for every variable 20–30 FPS sequence: 24/25 may still produce 48/50 FPS on a 60 Hz display. A separately validated target-time-grid resampler is required for that guarantee.

3× 在合适条件下自动选择。它不等于任意 20–30 波动序列恒定输出 60：60Hz 屏上的 24/25 内容仍可能输出 48/50。恒定目标时间网格的重采样仍待独立实现和验收。
