<div align="center">

# MoniView

**原生、轻量的 macOS UVC / HDMI 采集卡监看器。**

实时预览、音频监听、录制、色彩工具与 MetalFX 空间放大，基于 SwiftUI、AVFoundation、Metal、Core Image 与 VideoToolbox，不依赖第三方运行库。

**[English](README.md) · 简体中文**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-f05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-16a34a.svg)](LICENSE)

</div>

> **状态：早期预览（0.2.0）。** MoniView 是本机 ad-hoc 签名的开发版，未做公证，未上架 Mac App Store。支持 macOS 14 及以上。界面跟随系统语言：简体中文或英文。

MoniView 把 USB（UVC）采集卡变成 HDMI 信号源的低延迟监看窗口，适用于相机、游戏主机和其他 HDMI 输出设备。

## 功能

- 按设备实际上报的格式枚举分辨率与帧率，支持离散档位和 29.97 / 59.94 等非整数帧率。
- 预览只保留最新帧；采集、GPU 渲染、音频与视频编码使用独立队列，预览 GPU 最多一帧处理中。
- 实时监听采集卡音频输入，并显示电平。
- 录制 H.264 + AAC 的 `.mov` 文件。
- 色彩与锐化调节：亮度、对比度、饱和度、鲜艳度、高光恢复。
- 使用 MetalFX 在 GPU 上放大预览，并提供 Lanczos 兼容回退。macOS 26+ 可选 Apple 低延迟机器学习超分作为放大方式。
- 诊断快照仅写入本机。

## 截图

![MoniView 实时预览窗口](docs/images/moniview-window.png)

![MoniView 采集设置](docs/images/moniview-controls.png)

截图来自实际运行的 app，连接 Jemdo Video 采集卡。画面中的数值取决于所连设备，不是性能基准。

## 构建与运行

```sh
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

只需要 Swift 工具链，Xcode Command Line Tools 即可，不需要 Xcode 工程或完整 IDE。`Scripts/build-app.sh` 把 SwiftPM release 产物打包成 `build/MoniView.app`，包含 `Resources/MoniView.icns` 和打包的 `PrivacyInfo.xcprivacy`，并做 ad-hoc 签名。

可选 AI 路径需要 Apple Swift 6.2+ / macOS SDK 26+ 构建，并在支持该功能的 macOS 26+ 硬件上运行。较旧 Apple 编译器构建空间放大回退版，最低部署版本仍为 macOS 14。自定义新编译器搭配旧 SDK 时，可用 `MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh` 显式打包回退版，详见 [AI 超分工程说明](docs/AI_UPSCALING.md)。

脚本支持可选覆盖参数：`MONIVIEW_VERSION`、`MONIVIEW_BUILD`、`MONIVIEW_ARCH`、`MONIVIEW_SIGN_IDENTITY`、`MONIVIEW_DISABLE_AI=1`，以及 `MONIVIEW_ENTITLEMENTS=1`（用 `Resources/MoniView.entitlements` 与 hardened runtime 签名，用于沙盒验证）。脚本会校验签名、检查打包资源，并输出架构与版本。

首次启动需要摄像头权限来读取视频。只有监听或录制声音时才需要麦克风权限，采集卡音频也属于该权限；仅监看视频不要求授权麦克风。MoniView 自动选择 USB 视频设备和匹配的音频输入；其他输入可在设置中选择。

底部按钮：录制、画面信息、画质增强、色彩、设置。点击画面关闭已打开的面板。

「窗口 › 窗口置顶」使主预览窗位于普通窗口之上，并在重新启动后保留选择。原生全屏期间临时使用普通窗口层级，退出全屏后恢复保存的设置；不改变 Spaces 行为，也不抬高存储面板等其他窗口。

简要状态条显示设备名、实际缓冲分辨率和实测 FPS：窗口模式居中于顶部，全屏时移到左上角。详细画面信息卡打开在右上角，打开时隐藏简要状态条，关闭后恢复。简要状态条默认隐藏，可在设置中打开「显示设备状态」。增强标签由「显示增强状态」独立控制，也默认关闭；已有偏好会保留。

「画面比例」决定画面如何填满窗口：适应画面（完整显示）、填满窗口（保持比例、裁切超出部分）、拉伸填满（铺满窗口，画面比例可能变形）。

快捷键：`⌘S` 保存当前画面，`⌘R` 录制/停止，`⌘⇧M` 静音监听，`⌘I` 显示/隐藏信息卡，`⌘,` 打开设置，`⌃⌘F` 或双击画面切换原生全屏，`Esc` 关闭面板或退出全屏。全屏静止 3 秒隐藏按钮和鼠标，移动恢复。

## 保存当前画面

选择「文件 › 保存当前画面…」（`⌘S`）保存 PNG，默认文件名为 `MoniView-YYYYMMDD-HHmmss.png`。以执行命令时的最新帧与画面参数为准，而不是确认保存路径时的帧。PNG 处理和写入不占用采集/渲染队列，同一时间只允许一个保存操作。

PNG 保存完整源分辨率画面、当前色彩调节和源分辨率锐化，复用录制的 `VideoImageProcessor.recordedImage` 路径。不包含 AI/MetalFX 放大、适应/填满/拉伸等显示变换或界面叠层；仅控制录制的「录制预览色彩和锐化」开关不影响截图处理。取消不写文件，替换使用原子写入，无视频信号时禁用该命令。

## 画面与帧率

MoniView 同时设置设备和视频连接的帧间隔，避免设备设为 60 但连接仍输出 20。切换分辨率时若原帧率不支持，会自动使用新格式最高档。

右上信息卡显示实际缓冲尺寸和像素格式、采集/渲染帧率、音频电平和软件处理耗时。该耗时从视频回调到 GPU 完成回调，在最后一次主线程跳转之前计时，不包含 HDMI 设备、采集卡与屏幕扫描延迟。同一采集帧因调参而重绘，不重复计为新视频帧；采集丢帧与录制丢弃分别统计。

窗口最小化或被其他窗口完全遮挡时暂停预览渲染，采集、录制和音频监听继续进行。

处理链路、单机实测快照和测量边界见[性能说明](docs/PERFORMANCE.md)。

## 诚实的放大能力

MetalFX 空间放大器不需要多帧历史，无法创造采集信号里没有的真实细节。可选的 AI 方式使用 Apple 设备端低延迟超分模型（macOS 26+），逐帧重建合理的细节，但仍不等同于采集信号的真实分辨率。插帧是另一个默认关闭的实验性预览功能，见下方说明。

- **AI 超分**：macOS 26 及以上使用 Apple VTLowLatencySuperResolutionScaler；模型加载中、设备不支持或没有符合处理尺寸上限的倍率时，回退 MetalFX/Lanczos。实际引擎以信息卡为准。
- **MetalFX**：支持的 GPU 使用系统空间放大器。
- **Lanczos**：兼容路径；设备不支持 MetalFX 或放大比例超过其当前限制时自动回退。
- 目标：原始、1080p（长边 1920）、2K（长边 2560）、4K（长边 3840）、匹配屏幕。其他比例按长边计算并保持原比例；匹配屏幕使用显示器的绘制缓冲尺寸，桌面缩放模式下不保证与面板物理像素一一对应。

低延迟模式下目标是处理尺寸的上限，并进一步受可见画面尺寸限制，因此 2K 与 4K 可能得到同一个处理尺寸；信息卡显示实际处理到的尺寸。关闭垂直同步时可能撕裂；关闭低延迟模式会恢复显示同步和完整目标尺寸处理。两种模式都不改变采集输入分辨率。

这些功能只影响实时预览。

## 录制

录制默认包含所选色彩调节和原始分辨率的锐化，不包含 GPU 放大或界面叠层。锐化按原始分辨率应用，而预览可能在 MetalFX/Lanczos 放大后再锐化，因此录制文件不会与放大后的预览逐像素一致。在设置中关闭「录制预览色彩和锐化」即可保存未经处理的原始画面。H.264 编码通过 AVFoundation 使用系统编码器，可能是硬件或软件编码器，不保证使用硬件编码器。有音频时使用 AAC，封装为 `.mov`。

录制音频使用单个 FIFO，以约两秒媒体时长及时间戳跨度为上限，另有包数安全上限。编码器暂时繁忙时按顺序保留音频，超预算时丢弃最旧样本并计数，保留源时间戳。停止时最多等待两秒排空尾音，未能排空的部分计入丢弃提示，之后另行完成 MOV 封装。这是录制缓冲，不是额外的声音监听延迟。队列独立测试可运行 `./Scripts/test-audio-buffer.sh`；真实声音连续性与编码背压仍需接采集卡验证。

## 实测设备上限

在开发机上实测 Jemdo Video USB 采集设备：设备暴露的最高采集格式为 1920×1080、约 60 FPS，没有 4K 采集条目。HDMI 输入/直通规格与 USB 采集输出规格可能不同，以设备实际上报的格式为准；其他采集卡仍需在对应硬件上验证。

这是一台设备上的实测结果，不是通用性能承诺。

## 隐私

视频需要摄像头权限以读取 UVC 采集卡；只有监听或录制声音时才需要麦克风权限。MoniView 完全在本机运行，不收集数据，也不向外部服务发送数据。app 打包了隐私清单（`PrivacyInfo.xcprivacy`），声明不跟踪、不收集数据。导出媒体保存到你在存储面板中选择的文件，诊断快照写入 `~/Library/Logs/MoniView/diagnostics.json`，都只留在本机。采集卡序列号、设备标识和诊断日志可能包含可识别信息，请勿附到公开 issue 中。完整说明见 [docs/PRIVACY.md](docs/PRIVACY.md)。

## 平台与路线

当前仅 macOS，以 ad-hoc 签名的本机构建分发，未做公证，也不是 Mac App Store 构建，当前产物不能直接用于 Store 提交；分发清单与当前缺口见 [docs/APP_STORE.md](docs/APP_STORE.md)。iPad 版需要独立的 UIKit/触控目标、音频播放适配与单独签名；Mac 的 `.app` 不能安装到 iPad。iOS 版本不在本仓库，后续版本可能闭源；已发布版本沿用发布时的许可证。

后续方向是共用媒体处理和模型、保留小型原生平台外壳，而不是增加庞杂的桌面控制面板。已有复用切入点和仍然存在的平台依赖见[平台边界](docs/PLATFORM_BOUNDARIES.md)；本轮审查没有实现 iPad target。

## 参考

以下资料仅用于采集与渲染方案的对照，未复制任何第三方代码。OBS Studio 采用 GPL-2.0-or-later，仅参考其实现思路，未使用其源码。

- Apple：[Technical Note TN2445 — Handling Frame Drops with AVCaptureVideoDataOutput](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)
- Apple：[CAMetalLayer](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer) 与 [nextDrawable()](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer/nextDrawable())
- OBS Studio：[mac-avcapture 插件](https://github.com/obsproject/obs-studio/tree/master/plugins/mac-avcapture)（GPL-2.0-or-later）

## 参与贡献

构建与隐私约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，版本历史见 [CHANGELOG.md](CHANGELOG.md)。仓库提供一个仅构建的 workflow，只能手动触发，不会在 push 或 PR 时运行。

[工程审查](docs/REVIEW.md)区分已提交修复与需硬件验证的工作；[本地 AI 接手说明](docs/LOCAL_AI_HANDOFF.md)列出集成、构建、故障注入与真机验收步骤。源码审查和 Linux 测试不等于 macOS 构建或性能认证。

## 许可证

MIT，见 [LICENSE](LICENSE)。

### 原生验证

已测 Mac、采集设备、构建命令与剩余缺口见[本地验证记录](docs/LOCAL_VALIDATION.md)。应用按设备上报的格式和精确帧率选择，切换音频后重新应用所选视频格式。尚未认证所有 UVC 采集卡。标称支持 4K HDMI 输入不等于 4K USB 采集；处理目标不会改变采集分辨率。

### 可选画面插帧

支持的 macOS 26+ 硬件默认关闭。倍率关闭／2×与低、中、高质量分开，以2×预览帧率为目标；自动模式检查处理负担，可选强制开关忽略成本预算，但保留屏幕准入、期限和资源保护；原帧端点和清晰档中间帧可使用 MetalFX/Lanczos 放大，流畅档中间帧仅做一次较轻的最终缩放。插帧期间暂停独立 AI 超分，关闭插帧后恢复其准入。插帧本身不改变采集、录制帧率。见[尺寸、延迟、资源与验证边界](docs/FRAME_INTERPOLATION.md)。

采集 FPS 是设备交给 Mac 的帧率，不是游戏内部帧率。选择 30 FPS 只限制采集流，不能控制主机输出。「跟随」或「跳过重复插帧」开启后，才会依据相邻帧的完全像素重复估算内容节奏；静止画面、压缩／噪声导致的细微差异，或采集率已降到内容节奏时，都可能无法得到估算。跟随会等待估算稳定后调整 Mac 的采集率，录制期间暂停；内容之后变快需要手动调高。这不是游戏 FPS 遥测。本版尚未实现 ScreenCaptureKit 本机屏幕输入，详见[输入与插帧边界](docs/FRAME_INTERPOLATION.md)。
