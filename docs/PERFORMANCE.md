# Performance notes / 性能说明

## Pipeline

- Capture callbacks retain the newest `CVPixelBuffer` and return promptly. Late capture frames are discarded; there is no preview frame FIFO.
- Rendering is triggered by incoming frames instead of a fixed 30/60 Hz timer. Only one preview GPU command is in flight; a newer pending frame is requested after completion.
- Core Image and MetalFX share a Metal command buffer. There is no CPU pixel readback or explicit synchronous GPU completion wait in the preview. Drawable acquisition can still wait for an available drawable; do not confuse the nonblocking semaphore with an entirely nonblocking render path.
- Low latency mode limits enhancement to the visible display size. Turning it off restores display synchronization and full target-size processing; latency and GPU work may increase.
- Minimized or fully occluded windows skip preview rendering. Audio monitoring and recording continue.
- Recording uses a separate, bounded queue. Video and audio omissions are counted and reported instead of growing a queue indefinitely.

## Measurement definition / 计时口径

The reviewed implementation measures from receipt of a video frame to its first successful GPU completion callback, before queuing the final main-thread bookkeeping. Repainting the same capture sequence does not add another video-frame timing sample. GPU execution is the command-buffer interval, not display presentation time. The software interval still includes queueing, CPU work and completion-callback scheduling; it excludes input-source processing, HDMI/capture-card buffering and display scan-out.

本轮修复后的软件计时从收到视频帧，到该采集帧第一次成功的 GPU 完成回调，在最后的主线程收尾任务排队之前结束；同一 sequence 的调参重绘不增加视频帧计时样本。GPU 执行时间是命令缓冲执行区间，不是画面实际显示时间。软件区间仍包含排队、CPU 工作及完成回调调度，不包含信号源、HDMI/采集卡缓存和显示扫描。

The historical samples below are preserved developer observations, not measurements of these review changes. Their callback-to-GPU label came from the earlier path that also waited for a main-thread hop. A lower value after correcting that endpoint is not, by itself, evidence of faster rendering or lower end-to-end latency. No new hardware numbers are supplied in this review.

下方保留的是原开发记录，不是本批修复后的重测。历史“回调至 GPU”标签来自仍包含主线程跳转等待的旧路径；修正终点后数值变小，本身不证明渲染或端到端延迟得到改善。本轮没有提供新的硬件性能数字。

## Observed on one device

Manual checks on a Jemdo Video USB capture device and an Apple M5 Max confirmed that the actual buffer changed between 1280×720 and 1920×1080, and that the selected 30/60 FPS intervals took effect. The device advertised a maximum of approximately 60 FPS at 1920×1080, with no native 4K capture format.

One windowed 720p60 sample with MetalFX enabled reported 60 capture FPS, 60 render FPS, zero capture drops, **4.1 ms callback-to-GPU completion** and **1.7 ms GPU execution**. These are one-second diagnostic samples, not a benchmark or a guaranteed result. They exclude console processing, HDMI transfer, capture-card buffering and display scan-out. Software processing time is not end-to-end input latency.

## Practical defaults

A roughly one-minute recording at 1080p60 was checked with `ffprobe`: H.264 at 60 FPS, AAC stereo at 48 kHz and BT.709 color metadata. Setting saturation to zero also produced neutral chroma in decoded frames, confirming that the color setting reached the recording. This checks the recording path on one capture card, not audio playback quality or long-duration reliability.

Use the capture card's native 1080p60 format when available, fit aspect, low latency enabled and mild enhancement. A 2K/4K enhancement target does not turn a 1080p input into native 4K. Try disabling enhancement if rendering falls below capture FPS; change capture resolution only when the device/USB link is the limiting factor.

## 中文

采集回调只保存最新缓冲，预览按新帧触发，不使用固定刷新定时器。预览 GPU 最多处理一帧，没有 CPU 像素回读或显式同步等待 GPU 完成；但 drawable 获取仍可能等待资源。最小化或完全遮挡窗口时停止预览渲染，音频与录制继续。录制使用独立有界队列，过载会统计并提示视频丢帧和音频丢包。

在 Jemdo Video + Apple M5 Max 上手动确认过 720p/1080p 实际缓冲切换、30/60 FPS 间隔生效。一段 720p60、MetalFX 开启的窗口模式快照显示采集/渲染均为 60 FPS、采集丢帧 0、回调至 GPU 完成约 4.1 ms、GPU 执行约 1.7 ms。它只是单秒快照，不代表完整输入延迟，也不保证其他设备取得同样结果；计时口径变更见上文。

建议默认使用采集卡支持的原生 1080p60、适应画面、低延迟和温和增强。2K/4K 是 GPU 放大目标，低延迟模式按显示尺寸限制处理，不改变真实输入分辨率。渲染帧率不足时优先关闭增强；设备或 USB 带宽受限时再降低采集分辨率。

约一分钟的 1080p60 录制经 `ffprobe` 检查为 H.264 60 FPS、AAC 48 kHz 双声道、BT.709 色彩元数据。将饱和度设为零后，解码帧的色度也呈中性，确认色彩设置写入录制。这只验证一张采集卡的录制路径，不代表已验证听感或长时间稳定性。

## Black preview with live frames / 有帧但画面黑屏

A capture card may continue delivering frames and silent audio while its HDMI source is paused or asleep. A live capture FPS counter confirms frame delivery, not valid HDMI content. During a manual check, an unprocessed recording contained uniform dark frames and silent audio; disabling enhancement did not change the preview. Check the source and HDMI connection before treating this as a rendering fault. Dark scenes alone are not a reliable signal-loss detector, so MoniView does not automatically label them as disconnected.

主机暂停或休眠时，采集卡可能继续发送暗色帧和静音。采集 FPS 代表有帧到达，不保证 HDMI 内容有效。本次手动检查的原始录制是均匀暗色帧和静音，关闭增强后预览仍相同；用户随后确认主机可能已暂停。遇到此情况先检查主机和 HDMI 连接。正常的暗场也可能接近黑色，因此程序不凭画面亮度自动判定断线。

## Next measurements / 下一轮测量

Use a clean baseline and candidate build under the same input, USB route, display mode and processing settings. Record actual capture/render rates, capture drops, recorder omissions, callback timing distribution, GPU time, memory trend and thermals. Use a real external comparison to assess end-to-end latency. Do not tune drawable count, move MTKView off the main thread or replace audio monitoring solely because a software timing number changed.

在同一信号源、USB 连接、显示模式和处理设置下对照干净基线与候选构建，记录真实采集/渲染帧率、采集丢帧、录制丢弃、软件计时分布、GPU 时间、内存趋势和热状态。端到端延迟需要外部对照测量。不能只因软件计时数字变化就修改 drawable 数量、将 MTKView 搬离主线程或更换音频监听实现。

## References

- [Apple TN2445: handling frame drops](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- [Apple Metal best practices: drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
- [Apple Metal best practices: command buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html)
- [OBS mac-avcapture source](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-avcapture) — design reference; no OBS code is included.
