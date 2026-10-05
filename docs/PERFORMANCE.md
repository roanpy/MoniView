# Performance notes / 性能说明

## Pipeline

- Capture callbacks retain the newest `CVPixelBuffer` and return promptly. Late capture frames are discarded; there is no preview frame FIFO.
- Rendering is triggered by incoming frames instead of a fixed 30/60 Hz timer. Only one GPU command is in flight; a newer pending frame is requested after completion.
- Core Image and MetalFX share a Metal command buffer. There is no CPU readback or synchronous GPU wait in the preview.
- Low latency mode limits enhancement to the visible display size. Turning it off restores display synchronization and full target-size processing; latency and GPU work may increase.
- Minimized or fully occluded windows skip preview rendering. Audio monitoring and recording continue.
- Recording uses a separate, bounded queue. Video and audio omissions are counted and reported instead of growing a queue indefinitely.

## Observed on one device

Manual checks on a Jemdo Video USB capture device and an Apple M5 Max confirmed that the actual buffer changed between 1280×720 and 1920×1080, and that the selected 30/60 FPS intervals took effect. The device advertised a maximum of approximately 60 FPS at 1920×1080, with no native 4K capture format.

One windowed 720p60 sample with MetalFX enabled reported 60 capture FPS, 60 render FPS, zero capture drops, **4.1 ms callback-to-GPU completion** and **1.7 ms GPU execution**. These are one-second diagnostic samples, not a benchmark or a guaranteed result. They exclude console processing, HDMI transfer, capture-card buffering and display scan-out. Software processing time is not end-to-end input latency.

## Practical defaults

A roughly one-minute recording at 1080p60 was checked with `ffprobe`: H.264 at 60 FPS, AAC stereo at 48 kHz and BT.709 color metadata. Setting saturation to zero also produced neutral chroma in decoded frames, confirming that the color setting reached the recording. This checks the recording path on one capture card, not audio playback quality or long-duration reliability.

Use the capture card's native 1080p60 format when available, fit aspect, low latency enabled and mild enhancement. A 2K/4K enhancement target does not turn a 1080p input into native 4K. Try disabling enhancement if rendering falls below capture FPS; change capture resolution only when the device/USB link is the limiting factor.

## 中文

采集回调只保存最新缓冲，预览按新帧触发，不使用固定刷新定时器。GPU 最多处理一帧，预览没有 CPU 像素回读或同步等待 GPU；缩小或完全遮挡窗口时停止预览渲染，音频与录制继续。录制使用独立有界队列，过载会统计并提示视频丢帧和音频丢包。

在 Jemdo Video + Apple M5 Max 上手动确认过 720p/1080p 实际缓冲切换、30/60 FPS 间隔生效。一段 720p60、MetalFX 开启的窗口模式快照显示采集/渲染均为 60 FPS、采集丢帧 0、回调至 GPU 完成约 4.1 ms、GPU 执行约 1.7 ms。它只是单秒快照，不代表完整输入延迟，也不保证其他设备取得同样结果。

建议默认使用采集卡支持的原生 1080p60、适应画面、低延迟和温和增强。2K/4K 是 GPU 放大目标，低延迟模式按显示尺寸限制处理，不改变真实输入分辨率。渲染帧率不足时优先关闭增强；设备或 USB 带宽受限时再降低采集分辨率。

约一分钟的 1080p60 录制经 `ffprobe` 检查为 H.264 60 FPS、AAC 48 kHz 双声道、BT.709 色彩元数据。将饱和度设为零后，解码帧的色度也呈中性，确认色彩设置写入录制。这只验证一张采集卡的录制路径，不代表已验证听感或长时间稳定性。

## Black preview with live frames / 有帧但画面黑屏

A capture card may continue delivering frames and silent audio while its HDMI source is paused or asleep. A live capture FPS counter confirms frame delivery, not valid HDMI content. During a manual check, an unprocessed recording contained uniform dark frames and silent audio; disabling enhancement did not change the preview. Check the source and HDMI connection before treating this as a rendering fault. Dark scenes alone are not a reliable signal-loss detector, so MoniView does not automatically label them as disconnected.

主机暂停或休眠时，采集卡可能继续发送暗色帧和静音。采集 FPS 代表有帧到达，不保证 HDMI 内容有效。本次手动检查的原始录制是均匀暗色帧和静音，关闭增强后预览仍相同；用户随后确认主机可能已暂停。遇到此情况先检查主机和 HDMI 连接。正常的暗场也可能接近黑色，因此程序不凭画面亮度自动判定断线。

## References

- [Apple TN2445: handling frame drops](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- [Apple Metal best practices: drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
- [Apple Metal best practices: command buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html)
- [OBS mac-avcapture source](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-avcapture) — design reference; no OBS code is included.
