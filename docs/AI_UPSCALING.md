# AI upscaling engineering notes / AI 超分工程说明

## Behavior / 行为

AI remains optional. Processing uses a supported scale factor no larger than the selected processing-size cap. When no factor fits, the source size is unsupported, the model is preparing, or setup fails, preview continues through MetalFX/Lanczos. A selected AI method does not mean every displayed frame used the AI model: consult the actual engine and processed dimensions in the info card.

AI 是可选路径，使用不超过当前处理尺寸上限的系统支持倍率。没有合适倍率、源尺寸不支持、模型准备中或初始化失败时，预览继续通过 MetalFX/Lanczos；选择 AI 不代表每帧都使用 AI，应以信息卡实际引擎与处理尺寸为准。

This is a per-frame ML enhancement, not native capture resolution or frame interpolation. No quality, frame-rate or latency improvement is claimed without a hardware measurement.

这是逐帧机器学习增强，不是原生采集分辨率，也不是插帧；未实测前不承诺画质、帧率或延迟收益。

## Lifecycle / 生命周期

Controller state is confined to the main-thread draw path. A serial worker prepares at most one session at a time. Publication checks the requested dimensions/factor and generation, so disabling enhancement, selecting native size or switching inputs cannot resurrect an obsolete warmup. Failed attempts use a monotonic retry deadline; an incoming frame does not postpone it.

控制状态限定在主线程绘制路径，串行后台队列同时最多准备一个会话。发布时核对尺寸、倍率及代次，关闭增强、选择原始尺寸或切换输入后，过期初始化不会重新生效；失败重试使用单调时间期限，不因每帧到来而不断延后。

Each configuration owns its own processor and pools. Submitted GPU work retains the session, pixel buffers, parameters and CVMetalTexture wrapper until completion. Retired processor sessions are ended on the worker, not synchronously on capture/render/UI queues. Attribute resolution and pool creation failures fall back rather than discarding the framework's required attributes.

每个配置拥有独立处理器与缓冲池。已提交 GPU 工作保留会话、像素缓冲、参数和 CVMetalTexture 包装直到完成；退役处理器在后台结束会话，不同步阻塞采集、渲染或界面队列。属性解析或建池失败时回退，不丢弃系统所要求的属性后强行继续。

## Toolchains / 构建工具链

The standard Apple Swift 6.2+ / macOS SDK 26+ toolchain builds the optional AI path, runtime-gated to macOS 26+. Older Apple compilers build the non-AI fallback and retain the macOS 14 deployment target. Compiler version alone is not an SDK probe: a custom new compiler paired with an old SDK must build with `-Xswiftc -DMONIVIEW_DISABLE_AI` or select SDK 26+. The build-only command for the explicit fallback is:

标准 Apple Swift 6.2+ / macOS SDK 26+ 工具链编译可选 AI 路径，运行时仍要求 macOS 26+。较旧 Apple 编译器使用非 AI 回退，保持最低 macOS 14。编译器版本不等于 SDK 检测：自定义新编译器配旧 SDK 时，需要 `-Xswiftc -DMONIVIEW_DISABLE_AI` 或选择 SDK 26+。显式回退的仅构建检查命令：

```sh
swift build -Xswiftc -DMONIVIEW_DISABLE_AI
```

This flag does not persist into a later invocation of `Scripts/build-app.sh`; select the intended Apple toolchain when testing a packaged app. Workflow triggers remain manual-only.

该参数不会自动传递给随后运行的 `Scripts/build-app.sh`，测试 app 包时请选择目标 Apple 工具链。workflow 仍仅手动触发。

## Local validation / 本地验证

```sh
swift --version
xcrun --sdk macosx --show-sdk-version
swift build
swift build -c release
./Scripts/build-app.sh
open build/MoniView.app
```

On supported macOS 26+ hardware, use a real UVC 1080p60 signal. Switch AI/MetalFX/Lanczos, 720p/1080p, target sizes, enhancement on/off and native size, including during model warmup. Resize across factor boundaries, minimize/restore and reconnect the source. Verify fallback continues without stale-sized frames, AI can retry after a deliberately injected setup failure, and disabling during warmup never reactivates it. Watch memory after repeated transitions; a transient retiring session is not by itself a leak. Compare color with a real gray ramp/test pattern. Repeat on an older Apple toolchain and supported older macOS to verify non-AI builds.

在支持的 macOS 26+ 硬件接真实 UVC 1080p60，反复切换 AI/MetalFX/Lanczos、720p/1080p、目标尺寸、增强开关和原始尺寸，并覆盖模型加载期间的切换。拖动窗口跨越倍率边界、最小化/恢复及重连输入。确认回退持续工作、不出现旧尺寸画面，本地故障注入后能够重新初始化，初始化期间关闭增强不会重新生效。多次切换后观察内存，短暂保留退役会话不等于泄漏；使用真实灰阶/测试图比较色彩。另用较旧 Apple 工具链及支持的旧 macOS 验证非 AI 构建。

These changes have only received source review and Linux Swift syntax parsing; Apple SDK compilation, GPU lifetime validation and actual ML quality/performance still require local testing.

当前仅完成源码审查与 Linux Swift 语法解析；Apple SDK 编译、GPU 生命周期及实际机器学习画质/性能仍需本地验证。

## References / 参考

- Apple WWDC25, Enhance your app with machine-learning-based video effects: https://developer.apple.com/videos/play/wwdc2025/300/
- Apple toolchain / SDK compatibility: https://developer.apple.com/support/xcode/
- Apple Metal drawable lifetime: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html
