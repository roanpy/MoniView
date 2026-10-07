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


## Experimental interpolation follow-up — 2026-10-06 / 实验性插帧补充

Hardware remained Apple M5 Max; macOS 27.0.1 (26A434), Apple Swift 6.2.4, macOS SDK 26.2. The built-in display was configured to ProMotion and the native fixture reported a current 120 Hz limit. / 同一 M5 Max，内屏设为 ProMotion，测试时当前上限为 120 Hz。

### Measured native window / 原生窗口测量

A 39-second run of `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 ./Scripts/test-preview-interpolation-display.sh` used synthetic SDR Rec.709 420v 1920×1080 input, a 960×540-point native window with 1920×1080 drawable, Smooth mode, no extra sharpening and original output target. The 30 one-second acceptance windows all had at least 57 distinct source and 57 generated presentations. Actual presented spacing averaged **8.396 ms**, P95 **8.333 ms**. Drawable acquisition P95 was **0.071 ms**, maximum **2.726 ms**. Processing adapted down to **640×360**; source endpoints stayed 1920×1080. This is a narrower result than native-1080p interpolation or real UVC game acceptance.

39 秒测试使用合成 SDR 输入及真实窗口；30 个一秒验收窗口均达到每秒至少 57 张不同原帧及 57 张实际生成呈现。呈现间隔均值 **8.396 ms**、P95 **8.333 ms**；获取 drawable 的 P95 **0.071 ms**、最大 **2.726 ms**。中间帧自适应降为 **640×360**，原帧仍为 1080p，不能说成原生 1080p 插帧或真实 UVC 游戏验收。

Earlier strict runs failed the cadence checks; a 20%-per-slot margin repeatedly triggered a two-second cooldown despite inexpensive native endpoints. The revised policy keeps a 10% single-slot deadline margin and 20% for the entire midpoint-plus-endpoint cycle. The same strict check then passed. Timing-scope changes alone are not an end-to-end latency improvement. Subsequent review fixes preserve a successful midpoint's endpoint during soft overload and run callback-loss recovery before the latest-input guard; input-cleared fault recovery passed. The above strict run preceded those two boundary fixes; its numbers are not an assertion of a second strict run at the final commit.

早期 strict 测试失败；原帧较轻时，单槽固定 20% 余量反复触发冷却。改为单槽保留 10%、完整配对周期保留 20% 后，原验收条件通过。统计口径调整不等于总延迟改善。随后审查修复软超预算保留配对端点、无输入时仍检查回调失联；清空输入的故障测试通过。上述 strict 数字产生于这两项边界修复之前，不伪称最终提交已再跑一轮 strict。

### Executed regression / 实际回归

- Pure policy: **177 checks passed**, including fractional cadence, portrait/even sizing, adaptive limits and pair-cost rejection.
- Capture compatibility/history, audio FIFO and configuration revision tests passed.
- All **11** native writer fault scenarios passed again, including forced not-ready, sustained overflow, tail draining, replacement protection and commit failure.
- Native interpolation GPU fixture passed all **10** color/range/metadata/orientation paths and warmup cancellation/retained-resource checks under Metal API Validation.
- Spatial scaler GPU fixture passed **20 alternating calls with exactly two resource entries**, plus pending-evicted-entry readback under Metal API Validation.
- Native AI spatial fixture passed **three** color/orientation cycles under Metal API Validation.
- Lost-presented-callback tests passed with input stopped and again with input cleared; old layers retire without recycling outstanding tokens.
- Apple SDK debug/release and explicit non-AI debug/package builds passed; both localized strings linted successfully.

原生窗口的普通 smoke（包含最小化／恢复）与 strict 120 分支不同；strict 分支不执行最小化／恢复，不能用其通过结果代替该项验收。

### Remaining acceptance / 剩余验收

The Mac locked during final bundle UI acceptance. The new bundle was observed waiting for camera authorization before lock. Real UVC 1080p60→120, final-commit strict rerun, 720p/physical 4K temporal inputs, combined 2K/4K/Match Display throughput, moving game artifacts, long-term thermal/memory behavior and cross-display refresh are not accepted by these results. Prior base-branch UVC/AI observations above remain base-version evidence. / 最终界面验收途中锁屏，新包此前在等摄像头授权；上述缺口不计通过，之前稳定版本的真机结果不能挪作新插帧版证明。

The feature remains experimental and off by default. Source recording/PNG do not include generated temporal frames; independent AI spatial enhancement is suspended during interpolation while its preference is retained. Lowest interactive latency still means interpolation off. / 功能默认关闭、保持实验性；录制／PNG 不含生成时间帧，插帧时暂停独立 AI 超分并保留偏好，最低交互延迟仍应关闭插帧。

### Follow-up deployment / 本轮部署

The ordinary AI-capable arm64 development bundle **0.2.0 (10)** was installed in Applications after preserving the previous bundle. Strict codesign verification passed and the installed/packaged executable SHA-256 matched (`2ed671eaecdcc0530f350e2219e4b441438c224628a373ff3701a328363fef5e`). The Mac remained locked, so the installed bundle has not received final UI/UVC acceptance. / 普通 AI 版已备份后安装，签名和可执行文件哈希核对通过；锁屏限制下，安装后的最终界面与 UVC 验收仍未完成。这是本地开发部署，不是商店或公开 release。

## Efficient fallback follow-up — 2026-10-06 / 流畅档回退优化补充

### Real input baseline / 真实输入基线

After unlock, build 10 displayed upright Jemdo 1920×1080 approximately 60 FPS input with live audio. Display Settings was found at fixed 60 Hz, then changed through the native UI to ProMotion; the app reported a 120 Hz maximum and display-link period. At default 1512×982-point display resolution, the actual capture buffers were 420v but lacked YCbCr matrix, color primaries and transfer-function attachments. The renderer correctly used its Core Image conversion fallback rather than assuming Rec.709 metadata.

解锁后 build 10 可显示方向正确的真实 Jemdo 1080p60 画面和音频电平。系统起初为固定 60 Hz，通过原生设置改为 ProMotion 后，程序报告上限和显示链路为 120 Hz。内屏默认 1512×982 点；采集缓冲为 420v，但缺少矩阵、原色和传递函数附件，因此走 Core Image 转换回退，不伪造 Rec.709 元数据。

With Match Display (about 2300×1294 visible output), Vivid color and enhancement strength 1, Clear interpolation exceeded its processing gate and Smooth adapted to 640×360 yet still mostly fell back to source frames. Selecting original output, Natural color and strength 0 also did not establish 120 FPS in build 10. These are failed real-input observations, not an accepted before/after performance comparison. / 匹配屏幕、鲜艳和增强强度 1 时，清晰档超预算，流畅档降到 640×360 后仍主要回退原帧；改为原始目标、自然和强度 0 也未在 build 10 建立 120 FPS。不能把这组观察报告为已通过或同条件前后加速对照。

### Changes and executed checks / 修改与已执行检查

Smooth now uses faster affine input resampling when conversion fallback is required, and generated midpoints use one final resize instead of intermediate MetalFX/Lanczos enlargement. Original source rendering and Clear's Lanczos input path remain intact. This is a resource/quality tradeoff; fine moving details can soften or alias. The general enhancement badge remains tied to the source pipeline, with temporal dimensions/counts reported separately. / 流畅档转换回退改用较轻的仿射缩放，中间帧只做一次最终缩放；原帧和清晰档路径保留。该取舍可能使运动细节模糊或产生锯齿，不等于画质认证；空间标签与插帧数据分开。

- `./Scripts/test-frame-interpolator-gpu.sh`: all **11** color/range/orientation/lifetime cases passed with Metal validation, including the new fast nonzero-origin 1920×1080→640×360 fallback. / 11 场景通过。
- `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_METADATA=missing ./Scripts/test-preview-interpolation-display.sh`: **PASS**, **29/30** one-second acceptance windows met source/generated thresholds over 39 seconds. Actual presented spacing mean **8.420 ms**, P95 **8.333 ms**; drawable acquisition P95 **0.078 ms**, max **2.621 ms**. Input was synthetic 1920×1080 420v without color metadata, drawable 1920×1080, Smooth working size 640×360, original target and no extra sharpening. This includes the endpoint/watchdog and current rendering changes; it is still not real UVC acceptance. / 缺元数据合成输入 strict 通过，29/30 达标；已覆盖当前渲染及端点／恢复修复，但仍不是实际采集卡验收。
- Policy **177** checks, audio FIFO, configuration revision, capture compatibility and all **11** native writer fault scenarios reran successfully. Ordinary and explicit non-AI Apple SDK debug/release packaging and bilingual strings lint passed. / 上述非图形回归与构建通过。

### Pending physical acceptance / 仍待真机验收

The optimized build 12 opened but waited for camera authorization after its ad-hoc signing identity changed; the Mac then locked. It was quit before further isolated GPU work. New-bundle real UVC 1080p60→120, combined 2K/4K/Match Display throughput, motion quality, long-term thermals and other cards/displays remain unverified. The package does not change macOS camera permissions or weaken signing requirements. / 优化包 build 12 打开后因 ad-hoc 签名变化等待摄像头授权，随后锁屏；在继续离屏 GPU 测试前退出。新版真实 UVC120、各放大目标吞吐与运动画质等未验收，不修改系统权限或弱化签名要求。

### Optimized deployment / 优化版部署

The same production code was packaged as the ordinary AI-capable arm64 **0.2.0 (13)** and installed in Applications after backing up build 10. Strict signature verification passed; packaged and installed executable SHA-256 matched (`cc331ce9f1c631444b6c99e04dc377eaff0e583d471d934cf864f971b7fd3e9b`). Because the Mac remained locked, the new installation has not been launched or accepted on real UVC. The last UI benchmark selections (Smooth, original target, Natural and strength 0) have not been restored through the UI. / 普通 AI 版 build 13 已备份旧包后安装，签名与哈希一致。锁屏下未启动或完成真实采集验收；上次界面测试的流畅、原始目标、自然和强度 0 设置还未通过界面恢复。

## Joint temporal/spatial API experiment — 2026-10-06 / 联合时间与空间接口实验

An isolated fixture uses the public `spatialScaleFactor: 2` configuration and phase 0.5, fresh immutable 420v Rec.709 inputs with continuous PTS, and separate scaled-current/midpoint destinations. Processor and configuration remain alive through completion and `endSession()`. It does not change the deployed renderer.

隔离夹具采用公开 2× 空间配置和中点相位，逐帧更新不可变输入、连续 PTS，保活处理器与配置，分别读回放大原帧和中间帧；部署版不使用这条路径。

| Executed command / 已执行命令 | Result / 结果 |
| --- | --- |
| `./Scripts/test-joint-interpolation-gpu.sh --compile-only` | SDK 26.2 compilation passed; no GPU claim. / 编译通过。 |
| `./Scripts/test-joint-interpolation-gpu.sh --gpu` | Failed at 640×360→1280×720 readback: both destination planes were zero, while input colors/positions were correct. Earlier repeated-input variant also lacked a valid GPU timestamp; no throughput numbers accepted. / 两张输出为空，不能计通过。 |
| `MONIVIEW_JOINT_CASES=640 ./Scripts/test-joint-interpolation-gpu.sh --gpu` after configuration retention / 配置保活后 | Failed at steady command 2 due to zero/unavailable GPU timestamps before readback; this final fixture run is not a pass. / 稳态 GPU 时间无效，未达到读回检查。 |
| `MTL_DEBUG_LAYER=1 MONIVIEW_JOINT_CASES=960 ./Scripts/test-joint-interpolation-gpu.sh --async-diagnostic` | Failed: `VTFrameProcessorErrorDomain -19730`, “Processor is not initialized”, despite successful session startup. Repeating with configuration strongly retained through completion did not fix it. / 保活配置后仍未初始化。 |
| `MTL_DEBUG_LAYER=1 MONIVIEW_JOINT_CASES=1920 ./Scripts/test-joint-interpolation-gpu.sh --async-diagnostic` | Same -19730 at 1920×1080→3840×2160; no generated output or GPU/presentation timing accepted. / 4K 输出实验同样失败。 |

The configuration object reports spatial factor 2 and supported 420v, but the above processing did not succeed on this Mac/OS/SDK. The root cause remains unresolved; these observations do not prove an Apple bug, a hardware limitation or universal lack of support. They also do not invalidate the separately passing temporal-only fixture. The joint path is **not enabled in production**. / 根因未解决，不据此认定 Apple 缺陷、硬件限制或所有设备都不支持；不影响另行通过的纯插帧测试。联合路径未启用。

## Real UVC interpolation acceptance, builds 14–15 — 2026-10-06 / 真实采集卡插帧验收

Machine/环境: M5 Max, macOS 27.0.1, Swift 6.2.4, SDK 26.2, Jemdo Video UVC 1080p60 (420v, no color metadata), built-in XDR display switched to ProMotion (app reports 120 Hz link).

**Passed on real input / 真实输入通过**

- After the display was switched 60 Hz to ProMotion through the native UI, the app reported a 120 Hz link and 120 Hz cap. / 切换 ProMotion 后正确识别 120 Hz。
- Smooth tier at 1080p60 input: interpolation ran continuously ("插帧运行中"), 45-58 generated FPS on the rolling counter, adaptive working size 960x540 to 854x480, midpoint cost 5.8-6.6 ms against the 8.33 ms slot, zero capture drops, live audio monitoring. / 流畅档真实运行，生成 45-58 FPS，预算内，无采集丢帧。
- The status capsule now shows the real presented output ("插帧 X FPS" = presented sources + presented midpoints), hidden together with the engine badge via the 显示增强状态 setting. / 左上角状态条显示真实呈现帧数，可随增强状态设置一起隐藏。

**Changes shipped in these builds / 本批改动**

- Quality tier now steps its working size down under overload (floor 960 long edge) instead of refusing forever; native 1080p interpolation measured 14.5-18.2 ms versus the 7.5 ms admission budget on this machine. / 清晰档超预算时自适应降档，下限 960 长边；1080p 实测超出预算。
- After sustained headroom (P95 midpoint at or below 55 percent of the slot for about 90 presented midpoints, at most one raise per 10 s), the working size climbs back one rung; a rung that fails right after a raise is blocked for the rest of the session. / 有余量时逐级回升，回升后失败的档位本轮不再尝试。
- A CAMetalLayer that stops vending drawables (observed once as a stuck black preview with "呈现中断，重建预览" after the 60 Hz to ProMotion switch in fullscreen) now retires and rebuilds like a presentation failure. / 图层不再产出 drawable 时按呈现失败重建预览。

**Failed or pending observations, honestly recorded / 如实记录的未通过项**

- The stuck-preview recovery fix has not been re-verified against a real display-mode change; the Mac locked before that scenario could be rerun. / 刷新率切换恢复修复尚未实测复核。
- With other video apps active (VTDecoderXPCService, Telegram playback), source-path GPU time rose to 15-23 ms and render rate dipped to 38 FPS; the policy stepped down and fell back as designed. Quiet-system readings were 1.8-3.1 ms GPU earlier; a same-conditions rerun is pending. / 系统繁忙时源帧 GPU 时间升高，策略按设计降级；待空闲环境复测。
- 30 to 60 interpolation on real input and 4K target plus interpolation have not been exercised on this hardware yet. / 30 帧输入插帧与 4K 目标加插帧未实测。
- Redeploying the ad-hoc-signed package invalidated the camera grant (8 stale TCC entries had accumulated for this bundle id). After a tccutil reset the system logged the new request as AUTHREQ_PROMPTING with "Delaying prompt"; the Mac locked before the prompt could be accepted, so builds 14-15 are not yet camera-authorized on this machine. / 重打包导致摄像头授权失效，弹窗延迟出现；锁屏前未能点击允许。

## Stable local signing and build 16 — 2026-10-06 / 稳定本地签名与 build 16

Ad-hoc signing changes the cdhash on every rebuild, so each redeploy dropped the camera/microphone grant. A self-signed code-signing identity (MoniView Local Dev, RSA 2048, 10-year) now lives in a dedicated keychain (`~/Library/Keychains/moniview-signing.keychain-db`, random password in user-local `~/.config/moniview/signing-keychain-password`, partition list preset for codesign). `build-app.sh` accepts `MONIVIEW_SIGN_IDENTITY` + `MONIVIEW_SIGN_KEYCHAIN`, unlocks the keychain non-interactively, and signs through it; defaults remain ad-hoc for everyone else. Signing was verified working while the screen was locked. / 临时签名每次重打包都会让授权失效。新建独立钥匙串保存自签名身份，构建脚本可用环境变量解锁并用它签名，默认值对其他开发者不变；锁屏下签名已验证可用。

Build **0.2.0 (16)** deployed to /Applications with this identity (backup: `~/Developer/MoniView-app-backups/20261006-build15`), `codesign --verify --strict` passed, all three regression scripts and plutil lint passed. The UI change in this build reports total presented output FPS (sources + midpoints) in the status capsule, right HUD and enhancement sheet, replacing the generated-only numbers. / build 16 已用稳定身份部署，校验与回归通过；界面三处的插帧帧率统一为真实呈现总帧数。

**Pending on unlock / 待解锁后处理**: accept the camera and microphone prompts once (they were re-issued for the stable identity after the tccutil reset); grants then survive future rebuilds. Commits `6966981` and `64b87f1` are local only — the GitHub credential expired mid-session (gh token invalid, no keychain entry, SSH key not authorized), so `git push` needs re-authentication first. / 解锁后允许一次摄像头与麦克风弹窗即可，之后重打包不再失效。两个新提交仍在本地：GitHub 凭据已过期，需先重新登录再推送。

## Interpolation clarity, output counts and frame-rate shortcuts — 2026-10-06 / 插帧清晰度、输出计数与帧率入口

Environment / 环境: Apple M5 Max (sysctl), macOS 27.0.1, Swift 6.2.4, macOS SDK 26.2, built-in display reported at 120 Hz.

- Clear retains its 1920px long-edge cap and no longer secretly steps down to 960×540. Smooth stops its adaptive ladder at 854px instead of 640px; it still trades moving detail for cost. / 清晰档不再暗降到 540p；流畅档不再降到长边 640，但较低分辨率中间帧仍可能偏软。
- Admission checks midpoint <= 1.5 slots, source <= 0.9 slot, pair P95 sum <= 90% of the source cycle, and presentation deadlines. The displayed cost/budget now describe the pair. This is a scheduling-policy change, not evidence of faster GPU inference. / 准入与预算改用整对周期并保留单项及呈现期限；这不等于 GPU 推理加速。
- All output FPS surfaces count presented source + generated frames in one window. Source redraws are deduplicated across windows; epoch checks are atomic with counting, excluding retired streams. Native fallback reports its actual source output instead of zero. / 按实际上屏回调统计原帧与生成帧总和，原帧重绘去重、旧流计数过滤；回退时不再显示输出 0。
- The shortcuts show only advertised 30/45/50/60 choices; remaining advertised rates stay in the picker. Jemdo discovery reports 1080p/720p fixed approximately 30, 50, 60 FPS (also 10/20), no 45 FPS. Synthetic 45→90 results do not certify Jemdo at 45 FPS. / 按设备能力显示快捷档位；Jemdo 没有 45 档，不能将合成输入测试当作真机支持。

### Executed validation / 已执行验证

| Scenario / 场景 | Result / 结果 |
| --- | --- |
| Debug build; signed release packaging; strings lint; interpolation policy (181 checks); capture compatibility including output sampling/retired epoch regression | PASS |
| GPU interpolation fixture under Metal validation, including orientation/color/fallback/resource lifetime | PASS; synthetic pixels, no image-quality certification |
| Synthetic 1920×1080 @30, Clear, native target, real window | PASS smoke; measured working size 1920×1080, steady output 60 FPS, pair P95 examples 20.5–22.6 ms against 30 ms budget |
| Synthetic 1280×720 @45, Smooth, 4K target, low-latency cap disabled, real window | PASS smoke; steady output 90 FPS, work 960×540, pair P95 examples 11.0–11.4 ms against 20 ms budget. No native 4K midpoint or uniform 90 Hz spacing claim |
| Synthetic 1920×1080 @60, Clear, budget fallback allowed | PASS fallback/order/disable smoke; working size remained 1920×1080; 5 midpoints across the test, most windows output 60 with generation 0. This does NOT pass 60→120 |
| Synthetic @60, Smooth, ordinary window/minimize/restore/disable smoke after visibility guard change | PASS smoke; 695 presented midpoints in total; no >=85% target windows. This does NOT pass sustained 120 |
| Strict @60→120 | FAILED. Earlier attempts produced windows near 120 but failed acceptance; another run retired its layer at startup after missing presentation callbacks. Strict acceptance remains unresolved |
| Injected missing presentation callbacks with cleared input | PASS; old layer retired without recycling outstanding tokens |

Visibility is now checked before presentation timeout retirement, so an occluded/minimized window is not immediately treated as an active presentation failure. The regular smoke and injected-loss tests pass; this does not prove recovery from every screen-mode change. / 已先判断窗口可见性，再判断呈现超时；普通恢复与故障注入通过，不代表所有刷新率切换都已验证。

### Installed app / 部署与真实输入

Build 17 was installed with the same local signing identity and strict verification passed. Real Jemdo 1920×1080 420v @60 resumed without a new permission grant. Clear showed native output approximately 58–61 FPS, generation 0, working size 1920×1080, a pair cost example 27.9 ms against 15 ms, and live audio level/monitoring. Build 18 then added the conditional 50 FPS shortcut and was installed after backing up build 17; strict verification passed. / build 17 真实采集与音频恢复，清晰档超预算后仍正常显示原帧；build 18 已安装快捷帧率改动并通过签名验证。

Correction to the previous signing note: the keychain search-list command had concatenated the original keychain paths, which hid GitHub credentials. Restoring the separate original paths restored gh authentication; no credential refresh or new token was required. Persistent signing is intended to improve permission continuity, not a promise that macOS will never ask again. / 更正上一段：GitHub 失败由钥匙串搜索列表写错导致，恢复路径后登录恢复；稳定签名不能承诺永不重新授权。

Pending: real Jemdo 30/50 FPS interpolation, visual motion-artifact comparison, strict stable 120, screen refresh changes, native 4K UVC and other cards/computers, joint AI upscaling + interpolation, iPad. Neither these smoke tests nor callback FPS measure HDMI end-to-end latency. / 未完成项如上；帧率回调和窗口测试不测 HDMI 总延迟。

### 2026-10-06 — multiplier/quality split and force override (builds 19/20)

- Same M5 Max / macOS 27.0.1 / SDK 26.2 / 120 Hz display as above. Debug build, release bundle 19/20, local signing and string lint completed. Non-AI Swift build completed. Policy checks increased to 229; legacy/current settings, override defaults, shared presentation counters, interval dedup/reset and skip counters passed pure compatibility tests. These do not prove GPU throughput.
- The force switch bypasses measured budget and budget-driven resolution reduction, not display/runtime/input eligibility, presentation deadlines or GPU error handling. Medium uses a fixed 1280 long-edge cap; High uses 1920. All three status surfaces still report actual presented output and generated counts. 90/120 capture shortcuts are conditional on advertised support; Jemdo advertised no such rates and correctly did not show them.
- Synthetic 1080p50 / Medium / Force / native output: display-window smoke passed, 710 generated presentations total, 12 sample windows with generated count >=85% of the requested target. This was run with the production app present, so it is not an isolated comparative benchmark or proof of evenly paced 100 FPS.
- Synthetic 1080p60 / Low / Force: smoke returned PASS with 339 generated presentations but zero >=85% target windows; later zero-output windows invalidate a sustained-throughput interpretation. Strict 120 FPS acceptance has NOT passed.
- Real Jemdo 1080p50 / High / Force / MetalFX screen output recorded capture50, source-GPU43, generated36, actual output78 in a diagnostic sample. Real 1080p60 while changing quality recorded actual output71–101 across samples; these interactive samples are not a controlled average or speedup comparison.
- A later real 60 / Medium / Force / MetalFX screen-output observation in build20 recorded capture60, source-GPU49–52, generated39–43, actual output89–94, cost15.6–18.3ms against15ms nominal pair budget. It confirms override generation even over budget, not stable120 or a smoothness guarantee.
- The instrumented 50 FPS zero-render/zero-output condition reported `previewState=hidden`, while capture continued50. A screenshot of a bound window alone does not prove the window is visible to the compositor. It must not be counted as GPU-load failure. Earlier uninstrumented 60 zero-output observations remain inconclusive. No semaphore recycling or speculative GPU reset was introduced. Hidden state now reports presentation paused and resets presentation interval baseline.
- Still unverified: sustained120 under controlled visible-window conditions, game motion quality/ghosting, true HDMI-to-screen latency, arbitrary 45/50→60 conversion, native4K UVC, old60Hz Mac runtime, iPad, and alternative RIFE/Core ML performance.

### 2026-10-06 — exact duplicates, compact controls and strict pacing failure

- Same M5 Max / macOS 27.0.1 / SDK 26.2 environment. Detector test passed 41 checks for 420v/420f/BGRA, active rows versus padding, UV changes, image-interpretation metadata and conservative unsupported cases. Hot-cache CPU benchmark (100 calls after 3 warmups) averaged 132.0 µs for identical 1080p and 322.1 µs for identical 4K 420v in one local run; these are averages, not P95, real capture measurements or HDMI latency.
- `MONIVIEW_TEST_DUPLICATES=1 MONIVIEW_TEST_FPS=30 MONIVIEW_TEST_FORCE=1` display fixture passed the exact-skip assertion and order/disable/minimize smoke, with 232 generated presentations across the run. It deliberately repeats synthetic pixels with distinct PTS. It does not certify content-cadence retiming or identify game FPS.
- The visible-window strict test `MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_FORCE=1 MONIVIEW_TEST_KEEP_EFFICIENT=1 ./Scripts/test-preview-interpolation-display.sh` **FAILED** its assertion (exit 133): only 2/30 acceptance windows met the strict thresholds, mean presented interval 9.648 ms, P95 16.667 ms. Working size was 960×540; late pair-cost examples 4.87–6.82 ms fit the 15 ms budget, yet output samples were 82/92 FPS. This is evidence of missed presentation slots beyond inference budget. Force is not a guarantee of 120. Disabled fallback returned to native 60. No performance improvement is claimed from changing controls or statistics.
- Ordinary AI-capable release bundle build 23 and debug build completed with Apple SDK. Non-AI release packaging build 21 also completed earlier; that fallback bundle was not installed. Normal production still retains standalone AI upscaling but uses spatial scaling while interpolation is active.
- Compact enhancement controls move explanations to tooltips and force/duplicate controls into More options, retain real output/generated counts and processing budget, and cap panel height with scrolling. ScreenCaptureKit input and source-game telemetry are not implemented.

Still pending: stable real UVC 60→120, strict stable pacing, game ghosting/blur comparisons, native 4K capture, 60 Hz older Macs, iPad, and HDMI end-to-end latency. The synthetic strict failure must not be relabelled as a pass.

### Final control verification and rejected scheduling experiment

- Signed builds 23–25 were opened locally while refining the panel. In build25 the native UI verified content-sized height, collapsed More options, aligned dropdowns, real output/generated counts and budget fallback. Jemdo delivered 1920×1080 at approximately60; High with Force off showed native output60/61, generation0, measured pair cost18.9–21.2ms versus15ms in interactive UI samples. These are not a controlled performance comparison. The source image was black during these UI checks; no claim is made about motion quality or black-image root cause. No new camera/microphone prompt appeared.
- A trial aligning all requested times to the refresh grid and feeding presented times back into scheduling failed the same strict thresholds: 1/30 windows, mean10.136ms, P9516.667ms (exit133); many callbacks were one refresh late. The production app was stopped for this trial. Conditions differed from the earlier test, so this is not proof of a speed regression; it is no evidence of improvement. The trial was locally reverted and is not deployed.
- Final policy checks increased to234 after regression coverage for retaining an active GPU-error cooldown across a Force-only change. Changing Force still clears budget-only cooldown; it does not bypass the GPU error guard. Audio FIFO and configuration-revision scripts also reran successfully.
- Final normal bundle: build27, signed using the same local identity. Stable120 remains unresolved; detailed actual-presentation deadline tracing and bounded scheduling changes need separate acceptance before shipping.

### 2026-10-06 — completion budgets, input ownership and a bounded 120 FPS pass (build29)

Environment: Apple M5 Max, macOS27.0.1, Swift6.2.4, macOS SDK26.2, arm64. The production app was stopped for the strict synthetic-window runs below. No claim is made that all unrelated system GPU work was absent. / 环境如上；严格合成窗口运行时退出了产品预览，不声称整机没有其他后台工作。

**Implemented / 已修改**

- Matching native-size IOSurface source buffers can be retained directly when every known processor attribute, Rec.709, orientation and explicit Center top-field chroma requirement is satisfied. Unknown/conflicting chroma or SDK requirements retain conversion. The inputs are not mutated and all processing resources survive in-flight stop. / 满足全部条件的同尺寸输入省去两次源帧拷贝，未知或冲突信息保守回退，输入不修改且停止时仍保活。
- Pair budgets now use the larger of CPU+GPU timestamps or encode-start→completion-callback elapsed for each command. This corrects undercounted processor/queue waits; it is not acceleration, GPU utilization or HDMI latency. Force still bypasses budget, not deadlines. A deadline fallback no longer leaves the prior running label unchanged. / 修正遗漏等待的计时及过期运行状态，不宣称统计修改等于提速。
- Spatial-scaler failed-key pruning is periodic; per-key retry deadlines and two-entry resource ownership remain intact. / 减少每帧失败键清理，重试与保活规则不变。

**Executed / 已执行**

| Command or scenario / 命令或场景 | Actual result / 实际结果 |
| --- | --- |
| `swift --version`; `xcrun --sdk macosx --show-sdk-version`; `swift build`; release packaging via `Scripts/build-app.sh` | PASS, versions above; normal signed build29 produced |
| Non-AI Swift build and `MONIVIEW_DISABLE_AI=1 ... Scripts/build-app.sh` | PASS, signed non-AI bundle29 produced and launched; no unsupported ML dependency required |
| Audio FIFO, configuration revision, capture compatibility, exact-duplicate detector and interpolation policy scripts | PASS; policy248 checks and duplicate41 checks. These are not real UVC/audio stress acceptance |
| `plutil -lint` on both localized strings | PASS |
| `Scripts/test-frame-interpolator-gpu.sh` under Metal validation | PASS16 synthetic cases, including missing top chroma, missing both locations, conflicting bottom location, range/color/orientation/non-IOSurface fallback and native-input in-flight stop |
| `Scripts/test-metal-upscaler-lru.sh --gpu` under Metal validation | PASS:20 alternating calls, two cached resources, evicted resource retained through readback |
| Optimized `Scripts/test-interpolation-spatial-gpu.sh --gpu` | PASS10 compatible synthetic cases. Sources720p/1080p/4K; midpoint then spatial2K/4K output. Direct960→3840 exceeds the existing3× scaler guard and is explicitly excluded, not relabeled as PASS |
| Strict1080p60 / Low / Force / MetalFX2K, native960×540-point window, low-latency target cap off, sharpening strength0 | **PASS30/30** acceptance windows: actual source59.97 + generated60.00 = output119.97 FPS, mean presented interval8.336ms, P958.333ms |
| Repeat same strict configuration after explicit-chroma guard and synthetic metadata correction | **PASS30/30**: source59.97 + generated59.90 = output119.87 FPS, mean8.343ms, P958.333ms over30.000s. CAD callbacks120/sec are diagnostic only; acceptance uses actual positive drawable presented times |
| Synthetic1080p30 / High / Force / MetalFX4K, target cap off, strength0.35 | PASS ordering/bound/disable/minimize-restore smoke,464 generated presentations,15 windows at >=85% generation target; steady samples output60. Not a strict120, real4K capture or game-quality result |
| Synthetic1080p60 / High / Force off, native target, budget fallback allowed | PASS fallback/order/disable/minimize-restore smoke;616 generated presentations across the run but no >=85% target windows. Does not pass120 |
| Strict1080p60 / High / Force / native target | **FAILED0/30**, source47.43 + generated28.20 = output75.63 FPS; mean13.224ms, P9525.000ms. The high-tier result must not inherit the low-tier PASS |
| StrictHigh / Force / forced old source-copy path | **FAILED0/30**, native output60.00 FPS, generation0; the deadline prevented generation despite Force. Test-only comparison does not alter the product |
| Low + screen target run interrupted by lock/occlusion | SKIP exit2; not a performance failure or PASS |

Offscreen original/copy comparison used fresh adjacent420v synthetic buffers,2 warmups and20 measured commands per case. At1080p→2K the original path's mean CPU encode was0.140ms versus copy0.231ms, but completion wall means were10.973/11.339ms; at4K they were11.118/10.487ms respectively. This small sequential sample does **not** demonstrate a consistent total-path speedup. Original GPU timestamp spans near1ms omitted waits visible in completion wall time. The optimization removes copies; it is not advertised as a percentage throughput gain. / 离屏小样本只证明少做拷贝及 GPU 时间戳不能代表完整经过时间，不声称整条链路稳定提速。

**Deployment and real input boundary / 部署及真实输入边界**

Normal build0.2.0(29) was signed with the existing local identity, backed up the previous installed build27 and deployed to Applications. Strict codesign verification passed. Packaged and installed executable SHA256 both equal `967d1544a0093be9bebb649d57d94f1f3a665bba2b4b0a778f778ca0459eaf17`. The non-AI package was launched before restoring the normal package. Neither main nor a release was published, and workflow files were not changed. / 新版安装及签名、哈希一致性通过；旧版已备份，不合并main、不发release、不改手动构建策略。

After launch, local diagnostics confirmed Jemdo1920×1080,420v, capture60 and the audio-monitoring path, with missing top/bottom chroma attachments. This actual device therefore uses conservative conversion rather than receiving invented Center metadata. The Mac relocked before visible packaged-app acceptance: presented output0 while locked is **not** a120 test or a black-image diagnosis. No audible audio, live game motion, packaged visual quality or true device120 claim is made from these diagnostics. / 真机可确认采集格式、60帧及监听路径；缺失色度附件不伪造。重新锁屏后的输出0不能用来判断黑屏原因，也不能替代可见窗口、可听音频或真实游戏验收。

Pending: real Jemdo visible-window30/50/60 quality and pacing,120 with actual device metadata/conversion, full-screen game motion/blur, native4K UVC, other cards/Macs, older60Hz computers, joint neural spatial+temporal processing, long-term A/V recording/fault coverage, Thread Sanitizer and HDMI end-to-end latency. The existing standalone AI option remains present and paused during interpolation. No speculative scheduler/backend prototype was shipped. / 未覆盖项如上；独立 AI 超分保留但插帧期间暂停，未部署未验收的调度实验。

## Cadence unification and Flow Beta tier — 2026-10-07 / 节奏统一与光流 Beta 档

Same Mac, same SDK as above. Deployed build 0.2.0(45), signed with the local identity; previous installed builds backed up. / 同机同 SDK；部署 0.2.0(45)，本地签名，旧版已备份。

**Automated results / 自动化结果**

| Check / 检查 | Result / 结果 |
| --- | --- |
| `swift build` | PASS |
| `Scripts/test-frame-interpolation-policy.sh` | PASS 292 checks |
| `Scripts/test-content-cadence-policy.sh` | PASS 18 checks (stability, fractional rates, unique PTS cadence, presentation qualification) |
| `Scripts/test-video-frame-duplicates.sh` | PASS 41 checks |
| `Scripts/test-capture-compatibility.sh` | PASS |
| `Scripts/test-configuration-revision.sh` | PASS |
| `Scripts/test-audio-buffer.sh` / `test-recorder-faults.sh` | PASS |
| `MONIVIEW_TEST_FLOWBLEND=1 MONIVIEW_TEST_FPS=60 Scripts/test-preview-interpolation-display.sh` (120 Hz internal display, synthetic 1920x1080) | PASS: 60 source + 60 generated actually presented per second sustained across 15+ windows, pair P95 about 5 ms vs 15 ms pair budget, working size 1280x720, ordering/drawable-bound/disable/minimize-restore smoke all PASS |
| `Scripts/test-flow-blend.sh` | Image checks PASS (BGRA and 420v moving block). The 4 ms p95 gate is an idle-GPU gate: it passes with an idle GPU (about 0.7 ms median) and misses (about 5-8 ms p95) while the preview app itself loads the GPU; the runtime admission machinery handles the loaded case by backing off. |

**Real-device state / 真机状态**

The packaged app was driven to select the 光流 Beta tier with the real Jemdo 1080p60 420v input. Engine selection, tier persistence and the dedup path verified live: with static Switch output all 60 adjacent pairs per second deduplicate, no new presentation is produced, and the status reads "重复画面 · 跳过插帧" instead of the previous stale labels. Two stale-state bugs found by real observation and fixed: a permanently stuck "gpu-busy" preview state when all frames deduplicate, and the interpolation status never refreshing during full dedup (it could show a launch-time "refresh insufficient" forever). The "插帧运行中" label now reflects steadily presented midpoint+endpoint pairs; the stricter deadline check remains only the adaptive step-up gate after observing that sub-vsync phase made it permanently false at 8.3 ms slots despite perfect presented cadence. / 真机 420v 输入下光流档选择、持久化与去重路径已核实；静态画面下全帧去重、无新呈现、状态正确。修复两个真实观察到的过期状态问题。

**Not verified here / 未验证**

Real game motion quality of the Flow Beta tier (motion edges, dissolve fallbacks) still needs a gameplay session; the synthetic fixture validates throughput and presentation, not perceived quality. RIFE Core ML/MLX route remains shelved on measured cost (about 168 ms at 854x480 per pair on this M5 Max), not licensing (MIT). Flow Beta currently shares the macOS 26+ interpolation-section gate even though the engine is plain Metal. / 光流档真实游戏画质待游戏会话验收；RIFE 因实测成本搁置（MIT 许可无阻碍）；光流档暂随 macOS 26+ 插帧区门槛。


## Earlier 2026-10-07 snapshot / 2026-10-07 早期快照：输入节奏与三相位

These results precede the final 0.55 sharpening/Vivid/Follow matrix below; they do not certify the newer configuration. / 以下结果早于后述最终增强强度、鲜艳色彩及跟随组合，不能代替新配置验收。

- InputContentCadence isolated CPU fixture: 1143 checks, including 20/30/40/60 updates, source epochs, PTS discontinuities, stale observations and reset/publication races. CaptureManager consumes this input-side observer; rendering no longer supplies the estimate.
- Strict Flow Beta 1080p60→120, screen target 3024×1701, force ON, continuously visible near-fullscreen floating fixture: 30/30 eligible windows; source 59.73 FPS, generated 59.50, actual sum 119.23; mean interval 8.387 ms, P95 8.333 ms. Two fullscreen-Space attempts were inconclusive/failed presentation recovery and are not acceptance evidence.
- Flow 60-sampled / repeated-three-times source (20 unique FPS), screen target, exact dedup, force ON: steady 7/7 and restart 6/6 windows; source ~20, generated ~40. Full three-presentation pair structure passed before and after restart. Not a claim of constant 60 for arbitrary 20–30 variation.
- Flow image fixture: 235/235 checks passed. Separate performance sweeps are not general throughput or game-artifact certification.
- Production window-source audio lifecycle and short recording: selected external audio delivered while preview muted, source switch and audio off/on recovered; actual video/audio time-range overlap 2.401 s and track start offset 1.437 ms. This does not establish audible monitoring or long-duration AV sync.
- Real ScreenCaptureKit fixture after Retina/display/generation fixes: 16 checks; animated window 1600×1064 BGRA, increasing PTS, 280 frames in the observation; stop/restart and static identical content passed. Multi-display migration and real game input focus remain unaccepted.
- Build 92 installed with a stable local development certificate. Native Chinese capture UI verified: shortcuts and content reading share one row; full-rate, resolution and other dropdowns share their left edge. Build 92 is a local development bundle, not an App Store submission. Later UI size/shortcut changes require their own native confirmation.
- Required remaining acceptance: current real game moving scenes, all UI preset combinations after final build, arbitrary-cadence fixed-output resampling, optional original-window overlay/input behavior, sandbox/file permission runtime and App Store distribution signing.

## Current build 100 preset and readout acceptance / 构建 100 预设与读数验收

This section supersedes the build 96 preset behaviour below; the 60→120 results stay unchanged. / 本节替代下方构建 96 的预设结论；60→120 结果不变。

| Check / 检查 | Result / 结果 |
| --- | --- |
| Preset completeness / 预设完整性 | PASS: CPU table over capability sets {flow, quality}, {flow} and {} crossed with every previous engine state. Smoothness and Quality set enhancement on, their engine, force on and content-follow on; Native enhancement turns interpolation off; a missing engine falls back to off without claiming availability. The panel caption follows the resolved engine, so a fallback or a disabled engine is no longer described as the preset's own combination. / 能力集与历史引擎交叉表驱动通过；面板说明按实际解析出的引擎显示，回退或关闭不再写成预设原组合。 |
| Failure-path accounting / 失败路径 | PASS: a failed GPU command clears the queue, schedule, midpoint and published pair even when a colour edit changed the settings between encode and completion, and a late failure callback from an older stream or presentation epoch can no longer clear the state a newer generation published. / GPU 命令失败时即使中途改过色彩也会清理队列、排程、中点与已发布配对；旧代际迟到的失败回调不再清空新代际状态。 |
| Interpolated-pair readout / 插帧读数 | PASS: synthetic 30→60 with Follow, Flow engine and Match Display; a 20 Hz probe over 6 s of steady output read the published pair 120/120 times with zero missing samples and zero mismatches in the checked 2x regime, and disabling interpolation cleared it immediately. A 60→20 three-phase run passed the same presence check; its step is covered by the phase-structure assertions because the low-rate estimate keeps moving while that queue fills. Fake-clock checks cover the 1.25 s window, renewal re-arming it, expiry after renewal, an older epoch failing to republish, fallback non-renewal, future timestamps and hard resets. / 2×稳定窗口120/120次有效且无缺失；3×只断言读数存在，其步长由相位结构用例覆盖；假时钟覆盖窗口、续期、过期、旧代际不可覆盖与硬重置。 |
| 30→60 Flow switch/restart / 光流切换与重启 | PASS: switch 7/7 windows, restart 6/6 windows, source ≈30.0 + generated ≈30.0 FPS. Pair interval P95 measured 16.667–25.0 ms across runs at the Match Display target depending on GPU load, so uniform 60 Hz spacing is not certified. / 切换 7/7、重启 6/6；配对 P95 随 GPU 负载在 16.667–25.0 ms 之间波动，不代表均匀60帧间距。 |
| GPU suites / GPU 套件 | PASS in explicit GPU mode: flow-blend image checks (289/289), the frame interpolator fixture, and the spatial interpolation fixture (10 chained VT→MetalFX cases). The joint temporal/spatial script defaults to compile-only and its explicit `--gpu` path fails on this Mac; it is not on the production path and is not counted as a passing suite. / 光流图像（289/289）、插帧与空间套件按 GPU 模式实测通过；联合脚本默认只编译，显式 `--gpu` 在本机失败且不在生产路径，不计为通过。 |
| CPU suites / CPU 套件 | PASS: capture compatibility, frame-rate policy, configuration revision, content cadence, interpolation policy, input cadence, recorder faults, duplicate comparison, window audio, window policy, audio buffer, upscaler LRU. The real ScreenCaptureKit window fixture passed 16 checks; one earlier run hit a transient stop-time crash and passed on re-run, so a single green run is required per change. / 上述套件通过；窗口夹具 16 项通过，曾出现一次停止时的耦发崩溃，重跑通过。 |
| Localization / 本地化 | PASS: 263 keys per language, 123 source references, 526 bundle lookups and 4 permission messages. / 字符串与引用检查通过。 |
| Install and native smoke / 安装与实机烟雾 | Build 0.2.0 (100) signed, verified and installed over build 99; packaged and installed hashes both d1f2fea0baec3e4d424cef6ef45803a0fa6e252e19a237631c83a509856f008a. Selecting Quality enabled smooth interpolation, force and Follow with the high 1080p tier and a caption naming that engine; Smoothness switched to native-size Flow at 0.55; Native enhancement turned interpolation off at 1.00/Match Display. Real game motion on the capture card is still required before claiming the flicker fix for live gameplay. / 构建100签名安装、哈希一致；实机鼠标切换三个预设的开关组合与说明均正确，真实游戏运动画面仍需实机确认。 |

## Current build 96 matrix / 当前构建 96 验证

This section supersedes earlier performance claims for the configurations listed. All presentation fixtures use synthetic input on this Mac's 120 Hz display; they do not certify real game artifacts, controller/HDMI latency or other hardware. / 本节以所列配置的新结果替代历史性能结论。呈现测试使用本机120 Hz屏幕及合成源，不认证游戏伪影、操作／HDMI延迟或其他硬件。

| Check / 检查 | Result / 结果 |
| --- | --- |
| Localization / 本地化 | PASS: 254 keys in each language, 36 format signatures, 125 UI references including dynamic preset names/tooltips, 8 language preference orders, 508 Foundation bundle lookups and 4 permission descriptions. / 资源、格式、动态预设、提示、读取与回退通过。 |
| Input cadence / 输入节奏 | PASS: 1566 CPU checks; independent bounded worker, original PTS, stale/static/epoch resets. / 独立观察、原始时间戳、过期／静止及代次重置通过。 |
| Frame policy / 插帧策略 | PASS: 372 CPU checks; no GPU acceptance implied. / 策略通过，不替代GPU验收。 |
| Duplicate comparison / 重复帧比较 | PASS: 152 CPU checks, including tolerance early exit versus full-count reference at fractional boundaries, both 420 formats and BGRA. Strict equality is unchanged. / 容差超限早退与完整计数对照通过，严格去重不变。 |
| Capture settings / 采集设置 | PASS: capability-aware preset restore, native enhancement 1.00/screen/interpolation off, preferred engine persistence, stream-epoch publisher rejection, independent audio/window recording gates. / 能力回退、预设与代次发布等兼容检查通过。 |
| Flow image / 光流图像 | PASS: 289/289 GPU checks, including quarter/three-quarter correspondence. / 含非中点相位，图像检查通过。 |
| 30→60 Flow engine switch / 光流引擎切换 | PASS: 0.55/screen/force/Follow; switch to high quality then restore Flow; steady 7/7 and restart 6/6, source and generated ~30 FPS each, pair interval P95 16.667ms. / 切换恢复与完整帧对通过。 |
| 20→60 phases / 三相位 | PASS: 0.55/screen/force/Follow, steady 7/7 and restart 6/6; source 21.43 + generated 39.29 ≈60.72 FPS, full pair ordering verified. P95 25ms means this does not certify uniformly spaced constant60. / 三相位及恢复通过，帧距不计均匀恒60验收。 |
| Follow off/on / 跟随关闭恢复 | PASS: capture remains 60; OFF reports actual 60×2 and generated 57–58 FPS, restore ON reports actual content 30×2; original engine/force/target choices preserved. First restored window generated 23 FPS, so this is transition acceptance, not instantaneous steady throughput. / 采集档位不变、配对恢复通过；恢复首秒不计稳定吞吐。 |
| 60→120 screen pressure / 匹配屏幕压力 | FAIL: 0.55/Vivid/screen/Follow OFF, 26/30 strict windows (required ≥27), output 117.13 FPS. / 严格窗口数未达门槛。 |
| 60→120 unique input + Follow / 真实60内容跟随 | FAIL: final 0.55/Vivid/native/Follow ON, 7/30 strict windows, source 47.47 + generated 46.97 = 94.43 FPS, mean interval 10.590ms, P95 16.667ms. / 最终组合未达稳定120，不能按通过交付。 |

The adjacent-input pairing correction needs fresh same-epoch input cadence evidence. Unknown evidence still uses unique-content pairing; mailbox sequence gaps and extra comparison/GPU work remain suspected contributors to the Follow throughput loss, not proven sole causes. The bounded final retry stopped without relaxing the gate. / 相邻配对修正需新鲜同代次输入证据；未知时保留内容配对。观察丢样及比较／GPU负担仍是嫌疑，未证实单一根因；最后重测后停止，不降低门槛。

No shared multi-phase batch API ships: the experimental implementation was withdrawn before production integration. Overlay, actual sandbox runtime, store distribution and iPad remain staged work in [NEXT_BETA.md](NEXT_BETA.md). Variable20–30→constant60 is not implemented by integer3×. / 同帧对批次原型未接生产，已撤回；窗口覆盖、沙盒、商店与iPad见阶段计划，整数3×不代表任意波动恒60。

Build0.2.0(96) was installed with the existing local development certificate after protecting build92. Signature verification passed; packaged and installed executable SHA256 both equal `8b3a70b8cc820c257c604a19928586f9e952c984229688d01375755e12e3f7fa`. This is unsandboxed local development deployment, not store distribution. / 旧版已保护，构建96安装、签名与哈希一致；本地开发包未启用沙盒，不是商店分发。

Native macOS per-app language was temporarily changed to English and restarted, then its override was removed and restarted back to system Simplified Chinese. Final native screenshots/AX confirmed translated single-line preset buttons and Auto, aligned capture dropdowns, visible compact audio, English color labels and localized Refresh help. Native1.00 selected screen processing3024×1701 with interpolation off; switching back preserved off and explicitly enabling restored force. Actual UVC preview resumed after restart, including a single119-FPS reading with Follow off; this snapshot is not sustained120 or game-motion acceptance. / 实际应用语言切换及系统中文恢复通过，临时覆盖已移除；英文漏译、按钮换行及刷新提示已修正。原生预设实测匹配屏幕且插帧关闭，切回保留关闭、重新开启恢复强制；真实采集预览恢复，单次119读数不计持续120验收。
