# Contributing

Thanks for helping with MoniView. It is an early macOS preview, so small, reviewable changes are easier to evaluate than large ones.

## Ground rules

- Keep the app native and dependency-free: SwiftUI, AVFoundation, Metal, Core Image, and VideoToolbox. Do not add a framework that solves a single problem.
- Do not commit personal data. Capture card serial numbers, device identifiers, private file paths, usernames, and full diagnostic logs must stay out of issues, pull requests, screenshots, and documentation.
- Do not invent numbers. Performance, resolution, and frame-rate statements must come from a real run, state the device used, and be marked as measured on that hardware.
- Screenshots and sample media in the repository must come from the actual app. Do not fabricate a screenshot or paste a synthetic figure into a real one.
- Keep the preview path low-latency. Only the newest frame is retained, and do not introduce synchronous GPU/UI waits on capture or render queues. A nonblocking semaphore does not prove drawable acquisition cannot block; measure before changing the rendering architecture.
- MetalFX and Lanczos scaling are spatial, not neural super resolution. The optional VideoToolbox ML method is a different path; do not promise true source detail or performance improvements without validation.
- User-facing text uses the Simplified Chinese string as its localization key. When you add or change UI text, add the matching English value in `Resources/en.lproj/Localizable.strings` and keep the format placeholders unchanged.

## Build and check

Build locally with the Swift toolchain; the Command Line Tools are enough and no Xcode project is required. The optional AI implementation needs Apple Swift 6.2+ and macOS SDK 26+ to compile, and supported macOS 26+ hardware to run. Older Apple compilers use the non-AI fallback; deployment remains macOS 14. For a custom new compiler with an older SDK, explicitly use `MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh`.

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

Pure Swift tests can be run separately with `./Scripts/test-audio-buffer.sh` and `./Scripts/test-configuration-revision.sh`. Passing them does not validate AVFoundation, AppKit or GPU behavior. Integration and device acceptance steps are in [the local handoff](docs/LOCAL_AI_HANDOFF.md).

A build-only workflow is available for manual runs and is not triggered on push or pull request. Hardware behavior cannot be covered there, so describe the device and the format you tested against in the pull request.

## Pull requests

State the behavior change, the device and format you verified, the commands you ran, and any remaining gaps. Update the READMEs when a user-visible behavior, shortcut, or limit changes, and keep the English and Chinese versions consistent. Keep unbuilt or hardware-unverified changes clearly marked; do not report a syntax parse as an SDK build.

## 简体中文

感谢参与 MoniView。项目仍处于 macOS 早期预览阶段，小而可复核的改动更容易评估。

### 基本约定

- 保持原生、无第三方依赖：SwiftUI、AVFoundation、Metal、Core Image、VideoToolbox。不要为一个问题引入整套框架。
- 不要提交个人数据。采集卡序列号、设备标识、本机私有路径、用户名和完整诊断日志都不得出现在 issue、PR、截图或文档中。
- 不要虚构数字。性能、分辨率、帧率必须来自真实运行，注明所用设备，并标明是在该硬件上的实测。
- 仓库中的截图和示例素材必须来自实际运行的 app，不得伪造截图或把合成数字贴进真实截图。
- 保持预览低延迟：只保留最新帧，不得向采集或渲染队列引入同步 GPU/UI 等待。非阻塞信号量不代表 drawable 获取不会等待；修改渲染架构之前必须测量。
- MetalFX 和 Lanczos 是空间放大，不是神经网络超分；可选 VideoToolbox 机器学习路径应区别说明，未经验证不要承诺真实源细节或性能收益。
- 用户可见文案以简体中文原文作为本地化 key。新增或修改界面文案时，请在 `Resources/en.lproj/Localizable.strings` 补上对应英文值，并保持格式占位符不变。

### 构建与检查

用 Swift 工具链在本机构建，Command Line Tools 即可，不需要 Xcode 工程。编译可选 AI 实现需要 Apple Swift 6.2+ 和 macOS SDK 26+，运行时需要支持该功能的 macOS 26+ 硬件；较旧 Apple 编译器使用非 AI 回退，最低部署版本保持 macOS 14。自定义新编译器搭配旧 SDK 时，显式使用 `MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh`。

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

纯 Swift 测试可独立执行：`./Scripts/test-audio-buffer.sh`、`./Scripts/test-configuration-revision.sh`。通过这些测试不代表已验证 AVFoundation、AppKit 或 GPU 行为；集成与真机验收步骤见[本地交接说明](docs/LOCAL_AI_HANDOFF.md)。

仓库提供仅构建的 workflow，只能手动触发，不会在 push 或 PR 时运行；硬件行为无法在 CI 覆盖，请在 PR 中说明所用设备和格式。

### Pull request

说明行为变化、验证所用的设备与格式、执行的命令和剩余缺口。用户可见的行为、快捷键或限制变化时，请同步更新中英文 README。没有构建或未经硬件验证的改动必须明确标注，不得把语法解析说成 SDK 构建通过。

## Additional native checks / 补充原生检查

- `./Scripts/test-recorder-faults.sh`: forced readiness stalls through the actual AVAssetWriter; uses synthetic media, not a real capture card. / 用真实 writer 注入不就绪，媒体为合成样本。
- `./Scripts/test-capture-compatibility.sh`: production rate/target rules; not physical hardware coverage. / 验证生产代码的帧率与目标规则，不代表设备实测。
- `./Scripts/test-ai-gpu.sh`: SDK 26+ native GPU color/orientation/lifetime smoke; unsupported runtime is a skip. / 原生 GPU 色彩、方向与生命周期冒烟测试，不支持时明确跳过。

See [LOCAL_VALIDATION.md](docs/LOCAL_VALIDATION.md) before claiming acceptance or performance improvements. / 声称验收或性能提升前，核对实际验证边界。

Interpolation policy, GPU and native display fixtures are documented in [FRAME_INTERPOLATION.md](docs/FRAME_INTERPOLATION.md). Generated presentations and capture FPS have different meanings; do not equate a target multiplier with sustained FPS. / 插帧策略、GPU 与原生显示测试见该文档；实际生成呈现与采集帧率口径不同，目标倍率不能当作持续帧率。

`MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 ./Scripts/test-preview-interpolation-display.sh` requires an unlocked, visible 120 Hz display. It checks actual presented intervals and counts in a synthetic native window, not capture-card throughput or image quality. `MONIVIEW_TEST_PRESENTATION_FAILURE=1 MONIVIEW_TEST_CLEAR_INPUT=1` checks recovery after both callback loss and input clearing. / strict 120 测试需要解锁、可见的 120 Hz 显示器，检查合成原生窗口的真实呈现间隔与计数；故障变量覆盖回调失联及输入清空，不等于采集卡或画质验收。
