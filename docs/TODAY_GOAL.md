# Today's goal: locally usable capture preview / 今日目标：本机可用

## Final closeout scope — 2026-10-07 / 当日最终收尾范围

The user's final instruction is one bounded repair round, tests, Astra acceptance, and a GitHub commit/push. The current delivery gate is the local regression fix: usable Quality and Smoothness presets, interpolation recovery and truthful status, aligned enhancement controls and a stable audio meter. Store/iPad work and another extended subjective gameplay campaign do not hold this closeout open. Historical observations and their missing subjective verdicts below remain historical evidence, not fresh-build certification. Final results are recorded in [LOCAL_VALIDATION.md](LOCAL_VALIDATION.md).

用户最终要求为一轮集中修复、测试、Astra验收并提交推送GitHub。当前交付门槛是本机回归修复：画质与流畅预设可用、插帧恢复及状态准确、增强控件对齐和电平条稳定。商店、iPad及另一轮长时间主观游戏测试不阻塞本次收尾；下方历史观察及尚缺的主观结论仍只作历史证据，不作为最终构建认证。最终结果见[本地验证记录](LOCAL_VALIDATION.md)。

### Final closeout status / 最终收尾进度

- Build 114 is signed, installed and hash-matched; previous candidates are retained. / 构建114签名、安装和哈希核对通过，旧候选保留。
- Quality 30→60 and Smoothness 30→60 passed steady and restart gates; 20→60 three-phase, callback recovery, capture/window policies, real window capture and recorder fault tests passed. / 画质及流畅30→60稳定和恢复门槛通过，三相位、回调恢复、采集与窗口策略、真实窗口采集及录制故障测试通过。
- Native UI controls and bilingual resources checked; no claim of a fresh long gameplay verdict or stable High 60→120. / 原生控件及双语资源已检查，不冒称新的长时间游戏结论或High稳定120。
- Astra's read-only review returned PASS for this bounded scope, with no blocking P1/P2. The closeout changes and evidence are delivered by the corresponding GitHub commit/push; this round ends here. / Astra只读终验限定范围PASS，无阻塞P1/P2；本收尾提交推送交付修改及证据，本轮到此结束。

## Historical frozen acceptance plan / 历史冻结验收计划

The following plan and observations predate the user's bounded final closeout instruction above. Its uncompleted long gameplay/audio items remain uncompleted; they are not the current stop condition. / 下方计划和观察早于用户最终收敛范围的指令，未完成的长游戏及试听项目仍未完成，但不再作为本轮停止条件。

Scenario (frozen): this Mac + Jemdo capture card + 1080p60 capture + 30 FPS game content + 120 Hz display + the Smoothness preset (native input size, Natural colour).

Goal statement: ship a locally installable, interactive and continuously usable build on this Mac and capture card, focused on 30→60 interpolation and recovery, an operable simplified UI, honest status readouts, and a real-game plus short-recording acceptance.

Scope: App Store, sandbox migration, iPad, window overlay, sustained 60→120 and arbitrary 20–30 → constant 60 are explicitly out of scope today.

## Deliverables and acceptance / 交付物与验收

| # | Deliverable / 交付物 | Acceptance evidence / 验收证据 |
| --- | --- | --- |
| 1 | Operable common UI / 常用界面可直接操作 | Default window, zh and en: source, three presets, interpolation switch, status and recording are reachable without scrolling; advanced and colour details may collapse; no truncation, overlap or unclosable panel. Verify by clicking the installed app plus `Scripts/test-localization.sh`. |
| 2 | Presets and status tell the truth / 预设与状态准确 | Complete preset combinations; manual edits show custom; no engine shows unavailable. Status separates capture FPS, recent pair target, actual output and generated FPS, and never implies 120. Verify with `Scripts/test-capture-compatibility.sh` plus 10 live preset/switch rounds interleaved with resize, colour edits and minimize/restore. |
| 3 | Fixed-config 30→60 pass / 固定配置呈现通过 | Fixture gate unchanged: steady ≥6/7 windows, restart ≥5/6 windows, frame order, complete pairs, interval and drawable bounds, activity missing 0, steady-regime mismatch 0, immediate clear on disable. Command: `MONIVIEW_TEST_FLOWBLEND=1 MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_REPEAT=2 MONIVIEW_TEST_FOLLOW=1 MONIVIEW_TEST_FORCE=1 MONIVIEW_TEST_STRENGTH=0.55 MONIVIEW_TEST_TARGET=native MONIVIEW_REQUIRE_2X=1 MONIVIEW_TEST_RESTART=1 MONIVIEW_TEST_SWITCH=1 Scripts/test-preview-interpolation-display.sh` |
| 4 | Real game usable / 真实游戏可用 | Same game and scene observed for at least 10 minutes including pans, character motion, HUD text and a static menu; baseline with interpolation off, then Smoothness. Continuous motion holds about 30→60 pairs with no repeated running/waiting flicker, crash, black screen or freeze; the user confirms motion is acceptable and ghosting, tearing and latency do not block play. Record configuration, readouts, problem timestamps and the user verdict. User confirmation is required before this row can pass. |
| 5 | Recoverable local package and lifecycle / 可恢复交付包与生命周期 | Signed local build whose packaged and installed hashes match, previous usable build retained; 10 capture-device start/stop cycles and 10 window-source cycles without a crash; one 60 s recording that plays back with its selected audio; `Scripts/build-app.sh`, `codesign --verify --strict`, `Scripts/test-mac-window-capture.sh`, `Scripts/test-recorder-faults.sh`. |

## Order and stop conditions / 顺序与停止条件

1. Freeze the scope above and the baseline configuration.
2. Close correctness gaps first: failure callbacks, generation isolation, the transient window-capture stop crash and their tests.
3. Simplify the common UI and the status wording, then re-check in the running app.
4. Run the fixtures and package the real-device acceptance on one final version.
5. Optimise only while the primary scene misses its gate: one measured bottleneck per round, at most two implementation rounds, no new engine and no scope growth.

Pass means all five rows hold on one final build with the user confirming real-game quality; then stop changing code and publish the local entry point, configuration and known limits. Fail fast when the same gate misses after two rounds (keep the usable baseline, record evidence, never lower the gate), on any crash, black screen or corrupt recording (retire the candidate and bound the fix), or when the game, signal or user verdict is missing (stop at pending real-device acceptance). A SKIP, an older build's result or a single high FPS reading never counts as a pass.

## Not today / 今日不做

App Store submission, store signing and sandbox migration; iPad project and builds; window overlay, click-through and input forwarding; sustained 60→120 performance work; arbitrary 20–30 FPS to constant 60 resampling; new models or interpolation engines; unrelated refactors; cross-device certification, long recording certification, HDR or 4K combinations and end-to-end latency claims.

## Risks and preconditions / 风险与前置条件

- The user provides a stable capture signal, a repeatable 30 FPS game scene and the quality verdict; the display is at least 60 Hz.
- The fixture window must stay visible; no lock screen, occlusion or competing GPU load while it runs.
- Content-rate jitter or noisy capture repeats can prevent a steady 30→60; record it instead of masking it with a different capture rate.
- Flow Beta can still show visible artifacts; real-device acceptance must cover that risk.
- The transient window-capture stop crash is not yet explained; keep the crash log and check the lifecycle.

## Status / 进度

- Build 0.2.0 (100) signed, hash-matched and installed; previous usable builds kept under `build/archive/`.
- Passed on this build: `Scripts/test-capture-compatibility.sh`, `Scripts/test-localization.sh` (263 keys, 526 lookups), the fixed 30→60 fixture (7/7 steady windows, 6/6 restart windows, activity 120/120 with 0 missing, 0 mismatch in the 2x regime, immediate clear on disable), the 60→20 three-phase presence check, and the GPU suites (flow image, frame interpolator, spatial). The joint temporal/spatial script is compile-only by default and its explicit `--gpu` path still fails on this Mac, so it is not counted as a passing suite; it stays an isolated experiment outside the production path.
- Native UI check: the capture, clarity and colour panels fit without scrolling at the default window size in Simplified Chinese; picking a preset applies the whole combination and the caption names the resolved engine.
- Pending: the user verdict on row 4; the at-least-10-minute observation on this build is recorded in the build 100 table below. The 60 s recording inside row 5 is verified (75.2 s, 1920x1080 60 FPS plus 48 kHz stereo AAC). The Mac-window source listing still waits for Screen Recording permission.

## Real-device acceptance: build 100 / 实机验收：构建 100

Date 2026-10-07, this Mac, Jemdo capture card, 1080p60 capture, 120 Hz display, game running at about 30 FPS. / 2026-10-07，本机、Jemdo 采集卡、1080p60 采集、120 Hz 屏、游戏约 30 帧。

| Deliverable / 交付物 | Evidence / 证据 | Verdict / 结论 |
| --- | --- | --- |
| 4 Real game usable / 真实游戏可用 | **Configuration correction:** every recorded sample was taken with the app on the Quality preset and Vivid colour — each readout shows MetalFX 3024×1701, a match-screen target — so these samples do not prove the frozen Smoothness + Natural combination. Within that configuration: three samples 24 s apart stayed at capture 60–61 FPS, interpolation 30→60, output 63–64 FPS with 25–28 generated, forced interpolation running, no running/waiting flicker; a 12-minute window sampled 16 times without a restart (17:47:28–17:59:24; the process had been up since 17:34) read capture 60–61 FPS, interpolation 30→60, output 56–66 FPS with 22–28 generated every time, with no waiting flicker, black frame or freeze; the scene was the paused game with idle motion and a lighting change. Eight preset switches kept interpolation running with output rising 51→62 FPS; a dragged resize and a colour change recovered within seconds. Still missing: the frozen Smoothness + Natural run, an interpolation-off baseline, moving-camera and menu coverage, and the user verdict. / **配置更正：**记录期间应用处于画质优先＋鲜艳（读数恒为 MetalFX 3024×1701，属匹配屏幕目标），因此这些采样不能证明冻结的流畅＋自然组合。在该配置下：三段各24秒采样稳定为采集60–61、插帧30→60、输出63–64、生成25–28、强制插帧运行中，无待运行闪烁；同一进程12分钟连续采样16次未重启（17:47:28–17:59:24，进程自17:34起），每次均为采集60–61、插帧30→60、输出56–66、生成22–28，无待运行闪烁、黑屏或冻结，场景为暂停中的游戏画面，含待机动作与光照变化。8次预设往返切换插帧保持运行，输出51→62；拖动缩放与色彩改动后数秒内恢复。仍缺：冻结配置（流畅＋自然）的运行、关闭插帧基线、镜头运动与菜单覆盖，以及用户结论。 | NOT MET / 未达成 |
| 5 Local package and lifecycle / 交付包与生命周期 | Build 0.2.0 (100) signed, packaged and installed hash equal; previous builds 96/98/99 retained in build/archive. About fifteen capture-device/Mac-window source switches with no crash; the app stayed alive across every switch, and ten independent ScreenCaptureKit window cycles passed. A 75.2 s recording wrote 1920×1080 60 FPS video plus 48 kHz stereo AAC audio with matching durations, and reported 已保存到; independent decoding confirms a non-silent track. / 构建100签名与哈希一致，旧版保留；约十五次来源切换无崩溃，另有十轮独立窗口夹具通过；75.2秒录制为1080p60视频加48kHz立体声AAC，时长一致、音轨非静音。 | EVIDENCE INSUFFICIENT / 证据不足 (each source switch was not shown to deliver frames steadily, the recording's chosen audio source was not listened to, and the stop-time crash is still unexplained / 快速切换未逐轮证明稳定收帧，录像音源未试听，停止时崩溃仍未归因) |
| 1 Operable common UI / 常用界面可直接操作 | At the default window size in Simplified Chinese the clarity and colour panels fit without scrolling, the preset caption states the resolved engine, and the capture panel exposes source, resolution, rate, aspect and audio in one column. / 默认窗口中文下画质与色彩面板无需滚动，预设说明与解析出的引擎一致，采集面板单列呈现来源、分辨率、帧率、比例与音频。 | EVIDENCE INSUFFICIENT / 证据不足 (the English-locale layout and click-through were not exercised on the installed app; resource checks do not substitute / 未在安装版上验收英文界面布局与点击，资源检查不能替代) |
| 2 Presets and status tell the truth / 预设与状态准确 | Presets apply the full combination; a manual edit switches the caption to 已自定义; the HUD separates capture FPS, recent pair target, output FPS and generated FPS, and a mis-set Follow correctly showed 60→120 with 呈现节奏调整 instead of claiming success. / 预设完整应用，手动改动显示自定义，状态区分采集、配对目标、输出与生成；误关跟随时如实显示60→120与呈现节奏调整。 | NOT MET / 未达成 (two contradicting readouts, see the findings below / 出现两处与实际不符的读数，见下方问题清单) |
| 3 Fixed-config 30→60 / 固定配置呈现 | Fixture at native target and repeat 2 passed 7/7 steady windows and 6/6 restart windows with activity 120/120 and zero mismatches in the 2x regime. / 固定配置夹具平滑与重启窗口及读数检查通过。 | PASS |

Not covered: the user's own verdict on motion quality; Mac-window source listing until Screen Recording is granted; sustained 60→120; a second capture card; HDMI end-to-end latency. / 未覆盖：用户对运动画质的主观确认；录屏授权前的窗口来源列表；持续60→120；其他采集卡；HDMI端到端延迟。

## Independent acceptance, build 100 / 独立验收：构建 100

astra medium re-verified this build on 2026-10-07 with the app running and did not approve delivery. Row 3 passed twice under the frozen command (7/7 steady, 6/6 restart, activity 120/120, missing 0, mismatch 0); rows 1, 4 and 5 remain evidence-insufficient and row 2 is not met. Its three findings are carried as open work on the next build. / astra medium 于 2026-10-07 在应用运行状态下复验，未同意交付：第 3 项在冻结命令下两次通过（稳态 7/7、重启 6/6、activity 120/120、missing 0、mismatch 0）；第 1、4、5 项证据不足，第 2 项未达成。以下三项问题结转到下一构建。

1. **P2: a window source with no first frame reports running and keeps the previous picture.** MacWindowCapture.swift:303 publishes running as soon as the stream starts, CaptureManager.swift:780 sets `isRunning`, and MainView.swift:247 hides the waiting mask, while the renderer returns without input and the old drawable stays on screen; selecting a wallpaper or system window showed capture and output at 0 with the previous picture and, in one case, "forced interpolation running". Required: hold the waiting state and mask the old picture until the new source delivers its first valid frame, clear the previous interpolation state, and exclude system windows that cannot supply content. / 窗口来源没有首帧却显示运行并保留上一来源画面；要求首帧到达前保持等待、遮盖旧画面并清除旧插帧状态，排除不适合的系统窗口。
2. **P2: after a fixture restart the caption can contradict presentation.** With the frozen command one run presented source 30 + generated 30 from tick 22–30 while the caption stayed at preparing; the fixture must assert the caption as well (PreviewLayerView.swift:990, 1149, 1266). / 夹具重启后文字状态可能长期显示“插帧准备中”，与持续呈现的完整帧对矛盾；夹具需一起断言文字状态。
3. **P2: an enumeration error is wiped immediately.** CaptureManager.swift:729 sets `macWindowStatus` and the following stopMacWindowCapture():818 clears it; clean up first and keep the failure reason so the user can see it. / 窗口枚举错误提示被清理函数立即抹掉；应先清理再保留错误原因。

Record corrections from the same verification: the joint temporal/spatial script is compile-only by default and its explicit `--gpu` path fails on this Mac, so it is not a passing suite and stays outside the production path; and the real-device samples above were taken on the Quality + Vivid configuration, not on the frozen Smoothness + Natural one. / 同一次核验还更正了两处记录：联合时间／空间脚本默认只编译、显式 `--gpu` 在本机失败，不计为通过的套件，也不在生产路径；上表实机采样实际跑在画质优先＋鲜艳，而非冻结的流畅＋自然。

Verdict: build 100 is a candidate awaiting acceptance, not a delivered build. / 结论：构建 100 为待验收候选，不是已交付版本。

## Build 101: the three findings fixed / 构建 101：三项问题已修

Commit c70d3ad addresses the findings above; build 0.2.0 (101) is signed, packaged and installed (binary SHA256 9376af02fc973d5882d460a020eb082ddf92992d50f85751ac729e94a9b859d0, codesign verified, build 100 archived). / 提交 c70d3ad 修复上述三项；构建 0.2.0 (101) 已签名、打包并安装（二进制 SHA256 9376af02…59d0，签名校验通过，构建 100 已归档）。

- **First-frame rule / 首帧规则** — MacWindowCapture publishes running only after a complete frame arrives (with a 3 s deadline that reports `noPicture` and keeps the stream installed so a window that starts presenting later recovers by itself), callbacks are accepted while starting or silent, and system chrome (wallpaper, Dock, menu bar, window manager, notification centre) is no longer offered as a source. CaptureManager blanks the mailbox and asks the renderer to clear the drawable on every source change, reports a silent window as "所选窗口没有画面", and drops the previous pair readout. / 窗口来源只在首帧到达后发布运行（3 秒期限后如实报 noPicture 并保留流，稍后出画面可自恢复）；系统外壳不再作为来源；切换来源立即清空信箱并请求清屏，如实报告“所选窗口没有画面”，清除旧配对读数。
- **Caption truth / 标题如实** — the preparation label now passes through one reconciliation that yields to actual generated presentations, and the display refresh rate resolves identically in the display link and the interpolation configuration, so a mismatch can no longer reset the interpolation session every tick. / 准备状态由“确有生成帧上屏”裁决；显示刷新率在显示链路与插帧配置中一致解析，不再每 tick 重置插帧会话。
- **Enumeration errors / 枚举错误** — the failure reason is written after cleanup instead of being cleared by it. / 失败原因在清理之后写入，不再被清理抹掉。

Verified on this tree: `swift build`; `Scripts/test-localization.sh` (264 keys, 528 lookups); `test-capture-compatibility.sh`; `test-mac-window-capture.sh` (real ScreenCaptureKit, now 21 checks including the first-frame rule, the source list and a silent window); `test-window-capture-policy.sh`. The window-source source list dropped from 12 entries to 5 in a before/after probe, removing the wallpaper, Dock and notification-centre entries. / 本树验证：构建、本地化（264 键／528 次）、采集兼容、窗口采集（真实 SCK，21 项，含首帧规则、来源列表与静默窗口）与窗口策略套件通过；来源探测由 12 项降为 5 项。

Still open on this build: the frozen 30→60 command has not been re-run since the change because the console stayed locked from 18:52 on (the fixture reports SKIP on an occluded console, which is not a pass); a queued launchd job `dev.moniview.frozenwatch` runs it twice on the next unlock and writes `/tmp/moniview-frozen/run{1,2}.log`. The frozen Smoothness + Natural real-game run, an interpolation-off baseline, moving-camera and menu coverage, the English-locale UI pass and the user verdict are likewise still open. / 仍未完成：改动后尚未重跑冻结命令（18:52 起控制台锁屏，夹具在遮挡时按设计 SKIP，不算通过）；临时 launchd 作业会在解锁后自动跑两次并写日志。冻结配置（流畅＋自然）实机运行、关闭插帧基线、镜头运动与菜单覆盖、英文界面验收与用户结论同样待补。

## Build 103: acceptance on an unlocked console / 构建 103：解锁后的验收

Commit 3e5e299 carries the second review round (atomic source ownership with ingest tokens, bounded blank-presentation retry with an independent deadline, and midpoint-only caption evidence). Build 0.2.0 (103) is signed and installed (binary SHA256 c7fce63784ced24f72f5de1476afcd45550c7479468bafa066b31a3e25addeb9, build 102 archived). / 提交 3e5e299 为第二轮复核结果（带 ingest token 的原子来源归属、带独立截止时间的有界清屏重试、只认中点证据的标题裁决）。构建 0.2.0 (103) 已签名安装（SHA256 c7fce6…deb9，102 已归档）。

| Check / 检查 | Result / 结果 |
| --- | --- |
| Frozen 30→60 command / 冻结命令 | PASS twice: steady 7/7, restart 6/6, **caption non-preparing 6/6**, activity 120/120 with missing 0 and mismatch 0, complete pairs 179/209, interval P95 16.667 ms, stop/start restored. / 两次通过：稳态 7/7、重启 6/6、标题非准备 6/6、activity 120/120、完整帧对、间隔 P95 16.667 ms。 |
| Follow toggle fixture / 跟随开关夹具 | PASS: 60 FPS unique input, multiplier 2.00, generated 60 FPS, source ordering and drawable bounds hold. / 通过：60 帧唯一输入、倍率 2.00、生成 60 帧。 |
| Real game, frozen configuration / 真实游戏（冻结配置） | Smoothness + Natural on the installed build: 16 samples across 12 min 38 s (21:14:33–21:27:11 on 102 and 21:33:33–21:46:11 on 103, both runs sampled the same way and both held `插帧 30→60`), every sample on 103 read capture 60 FPS, interpolation 30→60 and output 60 FPS with 30 generated; no waiting, black frame or freeze; the scene showed the played game with moving characters. / 流畅＋自然：103 上 16 次采样跨 12 分 38 秒，每次均为采集 60、插帧 30→60、输出 60（生成 30），无待运行／黑屏／冻结，画面为正在游玩的游戏。 |
| Source switching / 来源切换 | Live: 5 device→Mac-window→device rounds; the window source listed real windows only (the wallpaper and window-manager entries are gone), captured ChatGPT at 3024×1824, and every return to the device restored 30→60. The real ScreenCaptureKit fixture reports 26 checks. / 实机 5 轮双向切换：窗口来源只列真实窗口（墙纸／窗口管理器条目已消失），捕获 ChatGPT 3024×1824，每次切回采集设备都恢复 30→60；真实 SCK 夹具 26 项通过。 |
| Recording / 录制 | 94.43 s file, h264 1920×1080 60 FPS, AAC 48 kHz stereo; audio verified non-silent (mean −28.7 dB, max −13.3 dB). / 94.43 秒，1080p60 + AAC 48 kHz 立体声，音轨非静音（均值 −28.7 dB）。 |
| English UI / 英文界面 | Launched with `-AppleLanguages (en)`: capture, enhance and colour panels read correctly, presets and status are translated, no truncation or overlap; the CI localization script still passes at 264 keys and 528 lookups. / 以英文启动：采集、画质与色彩面板完整可读，预设与状态均已翻译，无截断；本地化脚本 264 键／528 次通过。 |

Open items on this build / 本构建未闭合项:

- `MONIVIEW_TEST_ENDPOINT_EVIDENCE=1` traps (exit 133) with no output at all, and `MONIVIEW_TEST_PRESENTATION_FAILURE=1` traps after retiring the layer; both are fixture modes added by the fix and are being debugged. / 两个新增夹具模式崩溃，正在修。
- The preset label can stay on 已自定义 after a window re-creation even though every visible option equals the Smoothness preset; it under-claims rather than over-claims. / 窗口重建后预设名可能停在“已自定义”，属低估。
- A heavy window source (3024×1824) presents 38–40 FPS and reads 插帧待运行 while the content rate already exceeds the target; the caption does not yet explain that case. / 重窗口来源（3024×1824）输出 38–40 并显示“插帧待运行”，标题尚未解释该情形。
- The user verdict on motion quality is still outstanding. / 用户对运动画质的结论仍待补。
