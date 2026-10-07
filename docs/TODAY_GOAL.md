# Today's goal: locally usable capture preview / 今日目标：本机可用

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
- Passed on this build: `Scripts/test-capture-compatibility.sh`, `Scripts/test-localization.sh` (263 keys, 526 lookups), the fixed 30→60 fixture (7/7 steady windows, 6/6 restart windows, activity 120/120 with 0 missing, 0 mismatch in the 2x regime, immediate clear on disable), the 60→20 three-phase presence check, and the GPU suites (flow image, frame interpolator, spatial, joint).
- Native UI check: the capture, clarity and colour panels fit without scrolling at the default window size in Simplified Chinese; picking a preset applies the whole combination and the caption names the resolved engine.
- Pending: the user verdict on row 4; the at-least-10-minute observation on this build is recorded in the build 100 table below. The 60 s recording inside row 5 is verified (75.2 s, 1920x1080 60 FPS plus 48 kHz stereo AAC). The Mac-window source listing still waits for Screen Recording permission.

## Real-device acceptance: build 100 / 实机验收：构建 100

Date 2026-10-07, this Mac, Jemdo capture card, 1080p60 capture, 120 Hz display, game running at about 30 FPS. / 2026-10-07，本机、Jemdo 采集卡、1080p60 采集、120 Hz 屏、游戏约 30 帧。

| Deliverable / 交付物 | Evidence / 证据 | Verdict / 结论 |
| --- | --- | --- |
| 4 Real game usable / 真实游戏可用 | Foreground preview with Smoothness preset: three samples 24 s apart stayed at capture 60–61 FPS, interpolation 30→60, output 63–64 FPS with 25–28 generated, forced interpolation running, no running/waiting flicker. On top of that the same process was sampled 16 times across 12 minutes without a restart (17:47:28–17:59:24; the process had been up since 17:34): every sample read capture 60–61 FPS, MetalFX 3024×1701, interpolation 30→60, output 56–66 FPS with 22–28 generated, and none showed waiting, a black frame or a freeze; the scene was the paused game with idle motion and a lighting change. Eight preset switches (Smoothness↔Quality) kept interpolation running with output rising 51→62 FPS; a dragged resize and a colour change also recovered to 30→60 within seconds. / 前台预览在流畅预设下三段各24秒采样稳定为采集60–61、插帧30→60、输出63–64、生成25–28、强制插帧运行中，无待运行闪烁；同一进程另有12分钟连续采样（16次，17:47:28–17:59:24，进程自17:34起未重启），每次均为采集60–61、MetalFX 3024×1701、插帧30→60，输出56–66、生成22–28，无待运行闪烁、黑屏或冻结，场景为暂停中的游戏画面，含待机动作与光照变化。8次预设往返切换插帧保持运行，输出51→62；拖动缩放与色彩改动后数秒内恢复30→60。 | PASS with user verdict still pending / 通过，用户主观确认待补 |
| 5 Local package and lifecycle / 交付包与生命周期 | Build 0.2.0 (100) signed, packaged and installed hash equal; previous builds 96/98/99 retained in build/archive. About fifteen capture-device/Mac-window source switches with no crash; the app stayed alive across every switch. A 75.2 s recording wrote 1920×1080 60 FPS video plus 48 kHz stereo AAC audio with matching durations, and reported 已保存到. / 构建100签名与哈希一致，旧版保留；约十五次来源切换无崩溃；75.2秒录制为1080p60视频加48kHz立体声AAC，时长一致。 | PASS for device source and recording; Mac-window listing needs Screen Recording permission / 采集设备与录制通过；窗口来源需录屏授权 |
| 1 Operable common UI / 常用界面可直接操作 | At the default window size in Simplified Chinese the clarity and colour panels fit without scrolling, the preset caption states the resolved engine, and the capture panel exposes source, resolution, rate, aspect and audio in one column. / 默认窗口中文下画质与色彩面板无需滚动，预设说明与解析出的引擎一致，采集面板单列呈现来源、分辨率、帧率、比例与音频。 | PASS |
| 2 Presets and status tell the truth / 预设与状态准确 | Presets apply the full combination; a manual edit switches the caption to 已自定义; the HUD separates capture FPS, recent pair target, output FPS and generated FPS, and a mis-set Follow correctly showed 60→120 with 呈现节奏调整 instead of claiming success. / 预设完整应用，手动改动显示自定义，状态区分采集、配对目标、输出与生成；误关跟随时如实显示60→120与呈现节奏调整。 | PASS |
| 3 Fixed-config 30→60 / 固定配置呈现 | Fixture at native target and repeat 2 passed 7/7 steady windows and 6/6 restart windows with activity 120/120 and zero mismatches in the 2x regime. / 固定配置夹具平滑与重启窗口及读数检查通过。 | PASS |

Not covered: the user's own verdict on motion quality; Mac-window source listing until Screen Recording is granted; sustained 60→120; a second capture card; HDMI end-to-end latency. / 未覆盖：用户对运动画质的主观确认；录屏授权前的窗口来源列表；持续60→120；其他采集卡；HDMI端到端延迟。
