# Native validation / 原生验证记录 — 2026-10-06

This is a scoped development acceptance record, not a release or a certification of every capture card/Mac. No main merge or release was performed. / 本记录是开发阶段的有限验收，不代表所有采集卡或 Mac 认证通过；未合并 main、未发布 release。

## Integration / 集成

PR1–8 were all OPEN at inspection, independently based on main `e3b6d63`. Their current heads were integrated once, without force pushing or replacing their branches. / 核查时 PR1–8 均未合并，独立基于同一 main，本地只整合一次，未强推或改写原 PR 分支。

| PR | Integrated merge / 集成提交 | Current PR head / 核查 head |
| --- | --- | --- |
| 1 | 087727f | f7c5dd741c474b09a2488cf7da7f4f540f504f5b |
| 2 | 86d4c82 | 537f442a31c332b357f3196a34427d73b52a2459 |
| 3 | b152d4b | f9191823a654beb63dd452288572084fac59d018 |
| 4 | 37370e7 | f017b5666d33a74be4aa8fc7098f16d024d2ba58 |
| 5 | 537efae | 1ea923f23b8db1afcda3eae8343e87663088d5d0 |
| 6 | 052ef4c | 6ab159f260658497e780e222cb89392b24c8de6a |
| 7 | be842ce | 024ac4f8c905fcfacb8e6e2b463396c7381deb89 |
| 8 | 402b905 | 75dc8c55b580c2d3e538629e73bd2aada9d6877f |

Corrections on the integration branch / 集成分支修复：

- `e3924e9` — AI pools, shader write usage, RGB channel order, top-down rows, render-task error handling, GPU resource lifetime and retry wakeups. Changes `AIUpscaler`, `PreviewLayerView`, native GPU fixture/script. / 修复实际 AI 黑屏、偏色、颠倒及重试。
- `8bbcff5` — recorder commit failure cleanup plus compile-only fault hooks and tests. Changes `CaptureRecorder`, recorder fixture/script. / 修复提交失败临时文件残留，增加实际 writer 故障注入。
- `c4ba1cf` — direct device format ordering after session negotiation, exact rate priority, non-USB default discovery, final output-format checks and audio rollback. Changes `CaptureManager`. / 修复格式回退与输入协商。
- `e23a3fa` — 1080p processing target, explicit unavailable-AI UI fallback and compatibility tests. Changes settings model/view, bilingual strings and tests. / 新增 1080p 处理目标与回退显示。
- `fff6d96` — hidden-by-default status and separate enhancement-label preference. / 状态默认隐藏，增强标签独立开关。
- `4eecbd8` — audio choices are persisted only after successful configuration; failed choices retain saved disconnected-device preferences. / 音频配置成功后才保存偏好。

Original work was protected before edits. The first merges occurred in the existing integration checkout; final source/build checks use a separate validation worktree. / 修改前保留了工作区备份；初次整合位于已有集成检出，最终源码与构建复核使用独立验证 worktree。

## Actual environment / 实际环境

- Apple M5 Max, 128 GiB memory; macOS 27.0.1 (26A434).
- Apple Swift 6.2.4 (`swiftlang-6.2.4.1.4`), macOS SDK 26.2; arm64 app, deployment target macOS 14.
- Jemdo Video UVC and matching audio input. Tested actual buffers: 420v at 1920×1080, 1280×720 and 640×480. Advertised maximum USB capture observed: 1920×1080 at about 60.00024 FPS; no 4K capture choice was advertised. / 实际 USB 采集上限为设备上报结果，不依据 HDMI 4K 宣传推断。
- Built-in display backing store observed at 3024×1964; window/fullscreen exercised. No second display or second Mac/card available. / 已用内置显示器，未覆盖第二显示器、其他 Mac 或采集卡。

## Commands executed / 实际执行命令

| Command | Result / 结果 |
| --- | --- |
| `swift --version` | Apple Swift 6.2.4 |
| `xcrun --sdk macosx --show-sdk-version` | 26.2 |
| `./Scripts/test-audio-buffer.sh` | Passed limits, ordering, invalid input and reset / 通过 |
| `./Scripts/test-configuration-revision.sh` | Passed supersession and concurrent advancement / 通过 |
| `./Scripts/test-recorder-faults.sh` | All 11 native writer fault scenarios passed / 11 场景通过 |
| `./Scripts/test-capture-compatibility.sh` | Passed fractional/discrete/variable rate, format priority and target rules / 通过 |
| `./Scripts/test-ai-gpu.sh` | Three native 720p→1080p GPU cycles passed with Metal API Validation / 三轮通过 |
| `swift build` | Passed Apple SDK build / 通过 |
| `swift build -c release` | Passed Apple SDK release build / 通过 |
| `./Scripts/build-app.sh` | arm64 app built; signature and resources verified / 打包通过 |
| `plutil -lint Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings` | Both OK / 双语均通过 |
| `open build/MoniView.app` | Native UI and real capture exercised / 原生 UI、真实采集 |
| `swift build -Xswiftc -DMONIVIEW_DISABLE_AI` | Passed / 通过 |
| `MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh` | Packaged and opened; 1080p60 spatial fallback exercised / 实际回退包通过 |
| Thread Sanitizer revision test, default and explicit macOS 14 deployment | Both terminated with exit 139 before test output; sanitizer acceptance remains unverified / 两次均启动失败，不能计通过 |
| `git diff --check` | Passed / 通过 |

Helper/native fixtures are not substitutes for physical device tests. The recorder fixture currently emits two AVAsset track-loading deprecation warnings; these are not build failures. / 合成测试不替代真机，测试读取轨道 API 的两条弃用警告不属于编译失败。

## Observed acceptance / 已覆盖

- Real resolution switches 1080p↔720p and 1080p↔480p; 30/60 selection at 720p/480p and restoration to 1080p60. Verified actual delivered size and timing rather than just dropdown text. Audio reconnect restored the requested video format. / 核查实际缓冲与帧率，不仅看菜单。
- Real 1080p60 short recording: 32.766667 s H.264, 1966 video frames; 48 kHz stereo AAC duration 32.769958 s. Full decode completed without reported errors. This is not a clap/speech sync measurement or a long-run drift test. / 短录可完整解码，不等于外部音画同步或长期漂移验收。
- PNG command via Command-S: 1920×1080 source image saved; repeated command and cancellation exercised. Source snapshot/settings are captured before the save panel by code review. / 已保存源尺寸、重复与取消；命令时刻冻结逻辑已审查。
- AI 720p→1080p: real picture restored after fixing black output and vertical inversion. Synthetic GPU reads red/green/blue/gray centers accurately across three warmup/retirement cycles, with nonzero image origin. Actual 1080p AI selection falls back to MetalFX on this machine. / 真机画面方向恢复、合成读回正确；本机 1080p 不使用该 AI 模型。
- Recorder injected brief stall, sustained stall beyond 2 s media budget, ordered recovery, stop-tail recovery, permanent stall deadline, video-only, repeated sessions, failed-start reuse, same-name failure protection, successful replacement, injected commit failure and concurrent-start rejection. Sustained case received 260 PTS, dropped the oldest 157, accepted remaining 103 in order. Stop deadline completion observed at 2.02 s. / 故障注入为合成媒体进入真实 AVAssetWriter，确实覆盖不就绪分支。
- Status and enhancement visibility toggles; fullscreen/window layout and the five-entry controls; packed non-AI fallback. / 显示开关、窗口/全屏及回退包。

## AI usefulness and compatibility / AI 是否有用、兼容性边界

The model runs real inference and produces a larger buffer. It does not convert 720p input into native 1080p/4K source detail, does not interpolate FPS and is not guaranteed to improve every game scene. This machine supports a 1.5× factor for 720p; a 4K target or Match Display does not make that AI model produce 4K. Larger output may instead use MetalFX/Lanczos. Use native 1080p60 when the card offers it; reduce capture resolution to enable AI only for a measured benefit, not just the AI label. / 有真实推理与更大缓冲，但不能保证游戏画质收益；优先原生 1080p60，避免为 AI 标签主动损失源细节。

Capture formats and precise rates are enumerated per device; output types are rechecked after the format changes. Match Display resolves current backing-store dimensions on redraw and low-latency mode caps work to visible size. Unsupported AI falls back. These policies improve adaptability without certifying unknown drivers, USB bandwidth, GPU throughput or thermal behavior. Same-size FourCC choices remain automatically selected rather than exposed as another control. / 每设备动态枚举与协商，每次重绘按当前显示器计算；不保证未知驱动、带宽或性能，维持界面简洁。

No before/after latency benchmark is claimed. GPU completion/software callback intervals exclude HDMI transport, card internal buffering and screen presentation. / 没有同条件前后性能对照，不宣称加速；软件计时不等于 HDMI 总延迟。

## Not verified / 尚未验证

- Other cards/Macs/GPUs, physical 4K USB capture, 59.94/120 FPS hardware signals, portrait inputs and cross-display rendering.
- Long-duration sync/drift, audible head/tail listening against visible clap/beat, unplugging devices during recording, actual disk exhaustion and recording-while-quit.
- Real gray ramps/color bars, quantified quality comparison, HDR/10-bit/wide-gamut fidelity and extended GPU memory/thermal trends.
- Fault-injected capture/audio switch rollback and pixel-format-list changes on another driver (reviewed, not physically exercised).
- Entire native app under Thread Sanitizer; older macOS/Apple toolchain and Intel hardware; signed/notarized or sandbox App Store acceptance.
- Full PNG same-name/error/frozen-setting matrix; always-on-top behavior/persistence across panels, failure to enter fullscreen and multiple Spaces.
- iPad target or hardware acceptance. Existing platform boundaries are preserved; the Mac app is not already universal.

以上缺口均不计通过，保留在后续验收清单。/ These gaps are deliberately not marked passed.

## Final deployment / 最终部署

At the integrated revision, all five native scripts, debug/release builds, explicit non-AI build/package, and bilingual string lint were rerun in the independent validation worktree successfully. The ordinary AI-capable arm64 bundle, version 0.2.0 (3), was installed in Applications after backing up the old bundle. Signature verification passed; installed and validated executable SHA-256 hashes matched. Native UI showed an upright real UVC picture, 1920×1080 input, connected Jemdo audio with a live meter, and both status-label settings off. This is a local development deployment, not an App Store release.

集成修订已在独立 worktree 重跑五个原生脚本、debug/release、显式非 AI 构建/打包及双语 lint，通过后安装普通版 0.2.0 (3)。旧包已备份，签名核查通过，安装与验证可执行文件哈希一致。界面核查真实画面方向、1080p 输入及有电平的 Jemdo 音频，状态与增强标签开关关闭；这是本地开发部署。

## References / 参考

- [Apple: runtime super-resolution configuration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencysuperresolutionscalerconfiguration)
- [Apple: available video pixel formats](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/availablevideopixelformattypes)
- [Apple: machine-learning video effects](https://developer.apple.com/videos/play/wwdc2025/300/)
