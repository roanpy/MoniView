# Contributing

Thanks for helping with MoniView. It is an early macOS preview, so small, reviewable changes are easier to evaluate than large ones.

## Ground rules

- Keep the app native and dependency-free: SwiftUI, AVFoundation, Metal, and Core Image. Do not add a framework that solves a single problem.
- Do not commit personal data. Capture card serial numbers, device identifiers, private file paths, usernames, and full diagnostic logs must stay out of issues, pull requests, screenshots, and documentation.
- Do not invent numbers. Performance, resolution, and frame-rate statements must come from a real run, state the device used, and be marked as measured on that hardware.
- Screenshots and sample media in the repository must come from the actual app. Do not fabricate a screenshot or paste a synthetic figure into a real one.
- Keep the preview path low-latency. Only the newest frame is retained, and nothing on the capture or render queue may wait on the GPU or on the UI.
- GPU upscaling is spatial, not AI. Do not describe MetalFX or Lanczos as neural super resolution, and do not promise detail that was not in the source signal.
- User-facing text uses the Simplified Chinese string as its localization key. When you add or change UI text, add the matching English value in `Resources/en.lproj/Localizable.strings` and keep the format placeholders unchanged.

## Build and check

Build locally with the Swift toolchain; the Command Line Tools are enough and no Xcode project is required.

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

A build-only workflow is available for manual runs and is not triggered on push or pull request. Hardware behavior cannot be covered there, so describe the device and the format you tested against in the pull request.

## Pull requests

State the behavior change, the device and format you verified, the commands you ran, and any remaining gaps. Update the READMEs when a user-visible behavior, shortcut, or limit changes, and keep the English and Chinese versions consistent.

## 简体中文

感谢参与 MoniView。项目仍处于 macOS 早期预览阶段，小而可复核的改动更容易评估。

### 基本约定

- 保持原生、无第三方依赖：SwiftUI、AVFoundation、Metal、Core Image。不要为一个问题引入整套框架。
- 不要提交个人数据。采集卡序列号、设备标识、本机私有路径、用户名和完整诊断日志都不得出现在 issue、PR、截图或文档中。
- 不要虚构数字。性能、分辨率、帧率必须来自真实运行，注明所用设备，并标明是在该硬件上的实测。
- 仓库中的截图和示例素材必须来自实际运行的 app，不得伪造截图或把合成数字贴进真实截图。
- 保持预览低延迟：只保留最新帧，采集和渲染队列不得等待 GPU 或 UI。
- GPU 放大是空间放大，不是 AI。不要把 MetalFX 或 Lanczos 说成神经网络超分，也不要承诺原始信号中不存在的细节。
- 用户可见文案以简体中文原文作为本地化 key。新增或修改界面文案时，请在 `Resources/en.lproj/Localizable.strings` 补上对应英文值，并保持格式占位符不变。

### 构建与检查

用 Swift 工具链在本机构建，Command Line Tools 即可，不需要 Xcode 工程。

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

仓库提供仅构建的 workflow，只能手动触发，不会在 push 或 PR 时运行；硬件行为无法在 CI 覆盖，请在 PR 中说明所用设备和格式。

### Pull request

说明行为变化、验证所用的设备与格式、执行的命令和剩余缺口。用户可见的行为、快捷键或限制变化时，请同步更新中英文 README。
