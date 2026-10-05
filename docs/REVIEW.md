# Engineering review / 工程审查

## Scope and status / 范围与状态

Baseline: `e3b6d63f5f6300b0583ee94671246f3de8386ca2` on `main`. The review read both READMEs, CONTRIBUTING, CHANGELOG and all ten original Swift sources, plus build/localization/performance material. This document describes submitted changes, not a hardware acceptance certificate. PR status and current source are authoritative.

审查基线为上述 main 提交，已通读中英文 README、贡献规范、更新记录和原有十个 Swift 源文件，并核对构建、本地化及性能说明。以下“已提交”不等于已通过 Apple SDK 编译、合并或真机验收。接手前必须读取 PR 当前 head 与实际 diff，不能只按这份快照处理。

目标：做画面可信、响应及时、界面简单的小型监看器；保留底部五个入口，把新增保存和置顶放在原生菜单。没有加入第三方运行依赖、OBS/IINA 源码、自动工作流触发、虚构基准或 iPad 占位工程。

## Submitted fixes, ordered by impact / 按影响排序的已提交修改

| Priority | Problem / 问题 | Change / 修改 |
| --- | --- | --- |
| P1 | Recorder drops audio immediately at ingress limits or writer backpressure. / 录制音频入口及 writer 未就绪时直接丢弃。 | [PR 1](https://github.com/roanpy/MoniView/pull/1): one bounded media-duration/PTS-span FIFO, oldest-first eviction, existing drop counters, ordered drain, bounded tail drain and lifecycle cleanup. / 共用约两秒媒体预算，先旧后新，停止收尾和代次隔离。 |
| P1 | AI retries can be postponed by every arriving frame; setup/teardown and GPU ownership overlap. / AI 每帧推迟重试，会话切换与 GPU 资源所有权不清。 | [PR 4](https://github.com/roanpy/MoniView/pull/4): main-thread control state, per-configuration sessions, stale-result rejection, command-completion ownership, size-budget fallback and explicit SDK/toolchain fallback. / 明确生命周期与回退，不盲目增加工作尺寸。 |
| P1 | Configuration revision is written/read across queues without synchronization. / 配置代次跨队列裸读写。 | [PR 7](https://github.com/roanpy/MoniView/pull/7): a small locked revision token, atomic advancement and current-result checks, including stale format errors. / 锁仅保护标记，不包住设备操作。 |
| P2 | Software timing includes a post-GPU main-thread hop; redraws inflate frame counts; display changes can leave stale processing size. / 软件计时终点、重绘计数及跨屏更新不准确。 | [PR 5](https://github.com/roanpy/MoniView/pull/5): completion-callback endpoint, unique capture-sequence statistics, display/backing-change redraw and truthful native/sharpen label. / 不把口径改善冒充实际加速。 |
| P2 | Selected fractional rates, buffer format, localization and long-edge wording can mislead. / 分数帧率、缓冲格式、本地化及长边说明不一致。 | [PR 6](https://github.com/roanpy/MoniView/pull/6): precise rate selection, invalid-picker clearing, actual buffer FourCC, localized engine names and corrected descriptions. |
| Feature | Save the current image without adding another dock control. / 不增加底部按钮地保存当前帧。 | [PR 2](https://github.com/roanpy/MoniView/pull/2): File menu and Command-S, source-resolution PNG through the shared image processor, separate worker and native save panel. |
| Feature | Keep the preview above ordinary windows. / 主预览窗口置顶。 | [PR 3](https://github.com/roanpy/MoniView/pull/3): persistent Window-menu toggle, apply on actual window attachment, do not blanket-modify panels/Spaces. |

All seven PRs were submitted independently against the same baseline, not as a dependency stack. They may touch different parts of the same files. Integrate semantically: preserve both the snapshot command and window preference, both AI lifecycle and metrics changes, and all localized keys. Never resolve a conflict by replacing an entire shared file with one PR's version.

七个 PR 均独立基于同一基线，不是串联分支。同名文件有交集时应按语义合并，保留所有功能；特别是 MoniViewApp.swift、PreviewLayerView.swift、Localizable.strings 和 README，不能整文件选 ours/theirs。文档 PR 最后整合，保留前三个功能 PR 的录音、PNG 和置顶说明。

## What was actually checked / 已执行与未执行

The duration FIFO's production implementation passed a standalone Swift test covering ordering, duration/span/count budgets, invalid inputs, timestamp regression, reset and array compaction. The configuration revision's production helper passed supersession checks and 20,000 concurrent advances. These are functional test inputs, not throughput measurements. Selected new/modified Swift files also received Linux syntax parsing and source-diff review.

两组纯 Swift 测试运行的是实际 helper，而不是另写的模拟算法。此前对录制、导出、窗口、AI 正常/回退分支及预览文件做过语法解析；语法解析不验证 Apple 框架类型，也不运行 SwiftUI/AVFoundation/Metal。界面与采集改动做了逐段 diff 复核。

**Not performed here:** full Apple SDK build, code-signing/packaging run, native UI verification, real UVC capture, audio quality/sync, GPU resource validation, power/thermal measurements, or iPad execution. Draft status is intentional until local verification. Existing performance records are preserved as historical observations, not re-measured results.

**未在此执行：**完整 Apple SDK 构建、实际打包签名、原生界面运行、真实 UVC 采集、听感/音画同步、GPU 生命周期、功耗/热状态或 iPad 运行。不能把已提交或纯 Swift 测试通过表述成这些项目已验收。

## Hardware-dependent work deliberately not guessed / 有方案但未盲改

### P1: audio buffering and finalization / 音频积压与结束

The application FIFO is bounded, but retaining capture buffers can still exhaust a particular producer's pool. Apple's TN2445 describes the analogous video-buffer retention problem; applying that concern to an audio producer is a risk to test, not proof that every card is affected. Inject actual writer backpressure and inspect delivery, memory and drop accounting. Only add an owned PCM/data copy if tests establish a need; a shallow CMSampleBuffer copy is not proof of independent storage.

两秒只约束应用待写媒体，并不是监听延迟，也不是总退出耗时硬上限。最终 AVAssetWriter.finishWriting 的耗时属于另一阶段。用真实音频和故障注入核对起止 PTS、尾音、重复启停、设备拔出、磁盘失败及长录音画同步。还应比较设备 activeFormat 与实际音频样本描述；未经验证不要硬改采样率、重写时钟或加固定音频偏移。

### P1: Apple ML and color correctness / Apple ML 与色彩

Use the actual local SDK declarations and Metal validation. Verify configuration attributes, supported scale factors, output orientation, colors and lifetime while toggling during warmup. Do not substitute private APIs or make broad platform-support promises merely to silence a compiler error. Keep the spatial fallback usable independently.

用真实灰阶、色条和细节画面测试有限/全范围、不同 YUV 矩阵及宽色域显示。录制、PNG 与放大预览的处理尺寸和锐化顺序不同，不能要求三者逐像素相同，也不能因此随意覆盖源色彩附件。HDR/10-bit 全链路属于单独能力建设，本轮没有伪装成已支持。

### P2: drawable scheduling / drawable 调度

Apple documents that obtaining a drawable can block its caller when the pool is exhausted. MoniView's semaphore is nonblocking, but currentDrawable acquisition remains a measurement target. Measure acquire-to-commit and presentation behavior under real load before moving MTKView to another thread, changing drawable count, or restructuring offscreen passes. Preserve one preview frame in flight and newest-frame replacement.

当前没有为了“最佳实践”盲目把三缓冲改成双缓冲，也没有把 AppKit/MTKView 随意搬到后台。只有对照测量证明等待占比值得优化，再做独立、可回退的改动；不能用回调→GPU 时间声称 HDMI→屏幕总延迟。

### P2: capture format, power and recovery / 格式、功耗与恢复

The automatic format preference and native-format grouping still deserve real-card checks, especially devices that advertise 59.94 rather than exact 60. Runtime capability and actual samples should guide changes; do not invent a universal preference from one device.

还需验证最小化/遮挡时的显示休眠与 App Nap 策略、诊断写盘对 sessionQueue 的影响、掉线/重连及低帧率时的一秒状态窗口。是否拆分活动断言、降低诊断频率或改变采集停止策略，要以真实运行结果为依据，不能损害后台录制和监听。

## Design references / 设计参考

- [Apple TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html): prompt capture callbacks, latest-frame behavior, drop reasons and retention risk.
- [Apple Metal drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html): acquire late, release promptly, distinguish command completion from presentation.
- [Apple ML video effects](https://developer.apple.com/videos/play/wwdc2025/300/): framework session/configuration model; actual SDK and capability probes remain authoritative.
- [OBS mac-avcapture](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-avcapture/OBSAVCapture.m): serial session configuration and separate audio/video delivery queues; conceptual reference only, no GPL code copied.
- [IINA window handling](https://github.com/iina/iina/blob/0b975d58bb5b313f55938315c09dd5c01c67c61a/iina/MainWindowController.swift): per-player window level and fullscreen-aware behavior; conceptual reference only.
- [QuickTime Player recording guide](https://support.apple.com/guide/quicktime-player/record-a-movie-qtp356b55534/mac): a small recording interface and independent camera/microphone choice; playback and usability comparison, not evidence about its private buffering or latency.

Follow [LOCAL_AI_HANDOFF.md](LOCAL_AI_HANDOFF.md) for execution. Follow [PLATFORM_BOUNDARIES.md](PLATFORM_BOUNDARIES.md) for the future Mac/iPad direction without premature framework growth.
