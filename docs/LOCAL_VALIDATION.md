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
