# Window cadence repair and acceptance / 窗口节奏修复与验收

Date / 日期: 2026-10-22–23. Baseline / 基线: `ad3b604`, build 132.

## Outcome / 交付目标

With no capture card connected, an animated 20 FPS Mac window must reach the Flow 3× path through the production ScreenCaptureKit → input mailbox → preview renderer chain. Report actual source and generated presentations independently. Existing 30→60, 60→120, source-quality settings, queue bounds, GPU ownership, and stale-stream protection must remain intact. / 不接采集卡时，20 FPS 动画窗口须通过正式窗口采集、输入邮箱和预览渲染链路进入光流三倍插帧，分别核验原帧与生成帧实际呈现；保留已有 30→60、60→120、原帧画质设置、队列上限、GPU 生命周期及旧来源隔离。

This iteration covers cadence correctness, regression tests, bilingual documentation, and a verified local release. It does not add a new optical-flow algorithm, alter preset strengths, or expand App Store/iPad scope. / 本轮完成节奏正确性、回归测试、双语说明和经核验的本地版本，不新增光流算法、不改预设强度、不扩展商店或 iPad 范围。

## Findings to verify / 待验证根因

1. `nominalInputFPS` accepts only 20–60.25, while window capture requests the display rate, commonly 120 Hz. `PreviewLayerView` applies this content-processing range to the capture sampling rate. / 内容处理范围误用于窗口采样率。
2. `uniquePairPeriod` allows at most three sampling ticks. A 20 FPS source repeated in 120 Hz sampling spans six ticks. A fix must distinguish legitimate repeated content from missing/stale frames. / 六采样周期的真实低帧内容被拒绝；修复须有证据区分重复采样与丢帧。
3. Statistics compare successive estimates with 0.01 FPS tolerance. Measurements such as 20.017 and 20.031 cannot accumulate stability. These statistics do **not** gate renderer admission directly; fixing only this does not establish 3× correctness. / 统计容差过严，但统计稳定值不直接决定渲染准入，不能只修这一项。
4. A raw all-interval stability check may reject variable delivery from ScreenCaptureKit. Reproduce before changing it; never turn a missing or discontinuous timestamp into invented evidence. / 需核实变动投递间隔的影响，禁止把缺失、断续时间戳当作有效证据。
5. A small moving region can fall below the tolerant whole-frame noise allowance. The unchanged 1080p fixture reproduces this: 20 FPS content in 120 Hz sampling remains at 20 source + 0 generated on build 132. Record exact-repeat evidence independently inside the existing bounded worker; retain the tolerant UI estimate and reject evidence after a gap or source change. / 小范围运动可能低于整帧噪声容差；原有1080p夹具可复现132版在120 Hz采样时仅20原帧、0生成帧。应在既有有界工作线程内独立记录严格重复证据，保留界面估算容差，并在断流或换源后清除证据。

## Official guidance and application / 官方实践及本项目采用方式

- [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos): process complete samples and keep a bounded capture queue. Retain the current complete-frame gate and depth 5; idle callbacks are not new game frames. / 只处理完整样本，保留深度 5 的有界队列，空闲通知不作为游戏新帧。
- [minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval): the reciprocal specifies the **maximum sampling rate**. Treat it separately from unique-content cadence. / 此配置表示最大采样率，独立于内容更新率。
- [CMTime](https://developer.apple.com/documentation/coremedia/cmtime): use sample PTS and preserve rational/fractional timing. Do not replace PTS with rounded UI counters or callback arrival times. / 保留有理数时间戳及小数帧率，不用界面整数或回调时间替代。
- [Metal command buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html) and [triple buffering](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html): preserve build 132 shared pair analysis, bounded in-flight work and completion-based resource lifetime. Require measurements before further scheduling optimization. / 保留 132 已实现的帧对共享计算、有界在途工作和资源保活，进一步性能改造须有实测依据。

These sources support the engineering principles, not a claim that Apple certifies this implementation or a particular FPS. / 官方资料支持工程原则，不代表 Apple 为本实现或具体帧率背书。

## Implementation / 实施

1. Separate sampling-rate validation from supported content/interpolation rates. Admit high-rate repeated sampling only with bounded, fresh, same-epoch cadence and increasing-PTS evidence. Preserve legacy rejection of unexplained large gaps, stale/invalid samples and genuinely too-fast content. / 分开采样与内容范围，高采样低内容路径须具备新鲜、同代际、递增时间戳证据，仍拒绝无解释的大间隙。
2. Normalize stable statistical estimates conservatively around nearby supported rates; preserve 23.976/29.97/59.94 and nonstandard cadence, reset on actual changes/staleness/source switch, and avoid cumulative-drift acceptance. / 保守归一化统计，保留小数与非标准节奏，真实变速、过期与换源清零，避免逐步漂移误锁。
3. Add focused CPU regressions and an automated real-window integration fixture. The latter must create a known animated source, capture using production APIs, show the production renderer, assert actual generated phases/ordering/queue bounds, and cover static/resume plus stop/restart. A permission or visibility failure is SKIP, never PASS. / 新增策略回归与真实窗口集成夹具，核验生成相位、顺序、队列及静止恢复；授权或可见性不足不能算通过。
4. Keep interface wording and English/Chinese documentation consistent. Publish test evidence and limitations, then package/install and commit only after main-agent review passes. / 保持双语一致，由主代理审阅并验收后再打包部署和提交。
5. Take the endpoint and adjacent capture history under one mailbox lock. Separate reads race at 120 Hz and discard valid pairs even when their evidence is correct. / 端点与相邻采集历史在同一邮箱锁内读取；分开读取在120 Hz下会竞态并丢弃有效帧对。
6. Retain the newest consecutive exact-content pair in the existing bounded input worker. The renderer queue may still be presenting an older 3× batch, so its last presented source alone cannot identify the next real update. / 既有有界输入线程保留最新连续真实内容对；渲染队列可能仍在呈现旧三倍批次，只靠最后上屏原帧无法识别下一次真实更新。
7. Use the stable content estimate for the requested multiplier, while keeping the actual unique-pair period for deadline and slot decisions. This prevents timer alignment from switching a 20 FPS pair between 2× and 3×. / 倍率请求使用稳定内容估计，实际唯一帧对周期继续用于期限和时隙；避免定时器对齐令20帧帧对在2×与3×间跳变。

## Acceptance / 验收标准

- Release build; all existing CPU policy suites; five GPU suites; recorder faults; window capture; localization; fixture compilation. / 发布构建、现有 CPU 策略、五项 GPU、录制故障、窗口采集、本地化与夹具编译。
- Deterministic 20-in-60 and 20-in-120 tests must present both generated phases in order, approximately 20 source + 40 generated = 60 output, with complete pairs and bounded work. / 两种采样率均验证完整三倍相位及实际输出。
- Use the dedicated `MONIVIEW_REQUIRE_3X=1` gate for these two cases: seven steady windows, at least six within the existing throughput range, no missing/mismatched activity samples, the existing ordered-pair and P95 limits, and source MetalFX target-size checks in every window. The old 2× midpoint-quality recovery assertion stays unchanged for 2×; 3× may use the existing generated-frame spatial fallback, while the source target must remain intact. / 两组三倍测试使用独立门禁：七个稳态窗口至少六个达标、状态采样无缺失或错配、既有相位顺序及P95限制、每窗口原帧MetalFX目标尺寸检查。2×的中间帧画质恢复断言原样保留；3×可使用已有生成帧空间降档，但不得降低原帧目标。
- A real ScreenCaptureKit 20 FPS window must generate and recover after inactivity/source restart. Report measured counts, durations and P95; do not claim perfectly constant 60 from average FPS alone. / 实际窗口须有生成并可恢复，报告计数、时长、P95，不以均值冒充恒定帧距。
- The real fixture drives motion from its display link and asserts the first picture plus at most one bounded startup rebuild. Permission and visibility failures remain SKIP. / 真实夹具由显示链路驱动运动，核验首帧及最多一次有界启动重建；权限或可见性不足仍记 SKIP。
- Existing 30→60 and strict 60→120 thresholds remain unchanged. / 保持原严格验收阈值。
- Record absent USB capture hardware as an untested hardware boundary. Do not enable built-in cameras as a substitute. / 未连接采集卡的硬件链路明确未测，不自动启动内置相机代替。
- Stop when the bounded matrix passes; retain reproducible failure evidence and state any external prerequisite that blocks a required check. / 有限矩阵通过后收尾，失败留证并明确外部阻塞条件。
