# AI upscaling engineering notes / AI 超分工程说明

## Behavior / 行为

AI remains optional. Processing uses a supported scale factor no larger than the selected processing-size cap. When no factor fits, the source size is unsupported, the model is preparing, or setup fails, preview continues through MetalFX/Lanczos. A selected AI method does not mean every displayed frame used the AI model: consult the actual engine and processed dimensions in the info card.

AI 是可选路径，使用不超过当前处理尺寸上限的系统支持倍率。没有合适倍率、源尺寸不支持、模型准备中或初始化失败时，预览继续通过 MetalFX/Lanczos；选择 AI 不代表每帧都使用 AI，应以信息卡实际引擎与处理尺寸为准。

This is a per-frame ML enhancement, not native capture resolution or frame interpolation. No quality, frame-rate or latency improvement is claimed without a hardware measurement.

这是逐帧机器学习增强，不是原生采集分辨率，也不是插帧；未实测前不承诺画质、帧率或延迟收益。

## Lifecycle / 生命周期

Controller state is confined to the main-thread draw path. A serial worker prepares at most one session at a time. Publication checks the requested dimensions/factor and generation, so disabling enhancement, selecting native size or changing the requested configuration cannot resurrect an obsolete warmup. Failed attempts use a monotonic retry deadline and a generation-checked redraw wakeup; incoming frames do not postpone it. A superseded warmup also wakes the latest request when it finishes.

控制状态限定在主线程绘制路径，串行后台队列同时最多准备一个会话。发布时核对尺寸、倍率及代次，关闭增强、选择原始尺寸或更改请求配置后，过期初始化不会重新生效；失败重试使用单调时间期限，不因每帧到来而不断延后。相同尺寸和倍率的输入可复用同一配置，不把切换设备等同于强制重建模型。

Each configuration owns its own processor and pools. Submitted GPU work retains the session, pixel buffers, parameters and CVMetalTexture wrapper until completion. Retired processor sessions are ended on the worker, not synchronously on capture/render/UI queues. Attribute resolution and pool creation failures fall back rather than discarding the framework's required attributes.

每个配置拥有独立处理器与缓冲池。已提交 GPU 工作保留会话、像素缓冲、参数和 CVMetalTexture 包装直到完成；退役处理器在后台结束会话，不同步阻塞采集、渲染或界面队列。属性解析或建池失败时回退，不丢弃系统所要求的属性后强行继续。

## Pixel formats / 像素格式

The system low-latency scaler does not accept every pixel format at every size. On the local validation machine (Apple silicon, macOS 27 SDK 26.2) the supported-source limit is 1280x1280 and the accepted input is bi-planar YUV (420v) only; larger sources such as 1080p always take the MetalFX/Lanczos path, and a 720p source uses a 1.5x factor. These limits are read from the framework at runtime, not hard-coded.

系统低延迟超分器并非所有尺寸都接受所有像素格式。本机验证环境（Apple silicon，macOS 27 SDK 26.2）中，支持源上限为 1280x1280，且仅接受双平面 YUV（420v）输入；1080p 等更大源始终走 MetalFX/Lanczos 路径，720p 源使用 1.5 倍。上限在运行时从框架读取，不写死。

Earlier revisions forced BGRA pools, which failed on this hardware. The production path now preserves the framework's pool attributes, verifies 420v support, and renders into a private BGRA texture with shader-write permission. An explicit Core Image render destination reports encoding errors and writes top-down rows for CVPixelBuffer; the Metal converter reads logical RGB (not swapped BGR). Both stages and the scaler share the preview's single command buffer. Intermediate rendering and YUV attachments consistently use SDR BT.709. Unsupported formats or encoding failures fall back.

早期强制 BGRA 建池在本机失败。现在保留系统池属性、核对 420v 支持，中间 BGRA 纹理具备 shader-write 权限；显式 Core Image 渲染目标报告编码错误，并按 CVPixelBuffer 的从上到下顺序写行。Metal 转换使用逻辑 RGB，不交换红蓝。中间渲染与 YUV 标记均为 SDR BT.709，与超分共用预览的单个命令缓冲，不新增 GPU 等待。

Native production-path tests under Metal API Validation check four asymmetric red/green/blue/gray patches, a nonzero image origin, cancelled warmup and retirement while GPU work is in flight. Three 720p→1080p cycles passed on the local machine, with RGBA centers [255,0,0,255], [0,255,0,255], [0,0,255,255], [127,127,127,255]. This validates the exercised colors and orientation; it does not establish perceptual quality, HDR/10-bit fidelity, or every hardware combination. The earlier red/green-only probe had compensating red/blue errors and is not valid evidence.

Metal API Validation 下使用实际生产代码验证四象限非对称红/绿/蓝/灰图、非零图像原点、取消加载和 GPU 在飞时退役资源。三轮 720p→1080p 通过，色块中心 RGBA 如上；这不代表主观画质收益、HDR/10-bit 保真或所有硬件通过。早期仅红/绿的探针存在相互抵消的红蓝错误，不能作为证据。

## Toolchains / 构建工具链

The standard Apple Swift 6.2+ / macOS SDK 26+ toolchain builds the optional AI path, runtime-gated to macOS 26+. Older Apple compilers build the non-AI fallback and retain the macOS 14 deployment target. Compiler version alone is not an SDK probe: a custom new compiler paired with an old SDK must explicitly disable AI or select SDK 26+.

标准 Apple Swift 6.2+ / macOS SDK 26+ 工具链编译可选 AI 路径，运行时仍要求 macOS 26+。较旧 Apple 编译器使用非 AI 回退，保持最低 macOS 14。编译器版本不等于 SDK 检测：自定义新编译器配旧 SDK 时，需要显式禁用 AI 或选择 SDK 26+。

```sh
# Build-only fallback check / 仅构建回退检查
swift build -Xswiftc -DMONIVIEW_DISABLE_AI
# Package the same fallback / 打包时也显式使用回退
MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh
open build/MoniView.app
```

A SwiftPM command-line flag does not persist into later commands. The packaging environment variable explicitly forwards it to both the build and binary-path lookup. Run the script again without that variable for a normal build. Workflow triggers remain manual-only.

SwiftPM 命令行标志不会自动保留到后续命令；打包环境变量会明确把它传给构建和产物路径查询。需要恢复普通构建时，不带该环境变量重新运行打包脚本。workflow 仍仅手动触发。

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

Apple SDK builds, the native GPU smoke test and real Jemdo 720p AI / 1080p spatial fallback have been exercised. See [the dated validation record](LOCAL_VALIDATION.md) for exact coverage and omissions. Run `./Scripts/test-ai-gpu.sh` with SDK 26+; a runtime skip is explicitly reported and is not a pass. AI quality benefit, other Macs, long-term GPU resource trends and an older OS/toolchain remain unverified.

已执行 Apple SDK 构建、原生 GPU 测试、真实 Jemdo 720p AI 与 1080p 空间回退。具体覆盖与缺口见[验证记录](LOCAL_VALIDATION.md)。SDK 26+ 下可运行 `./Scripts/test-ai-gpu.sh`；不支持运行时会明确跳过，不计通过。画质收益、其他 Mac、长时间资源趋势和旧系统/工具链仍未验证。

## API provenance and distribution / API 来源与发行

The implementation uses Apple’s public VideoToolbox/Metal/Core Image interfaces and local SDK declarations, with no third-party runtime dependency or copied Lossless Scaling/OBS source. The scale-factor query uses the SDK’s public Swift overlay. Apple describes its low-latency super-resolution model as optimized for conferencing and compression artifacts; game-picture benefit is therefore an evaluation question, not a guarantee. Native 1080p capture is the recommended starting point when available.

实现使用 Apple 公开接口及本机 SDK 声明，没有第三方运行依赖或复制“小黄鸭”/OBS 源码，倍率查询使用公开 Swift 接口。Apple 的低延迟超分模型主要针对视频会议及压缩瑕疵，游戏画质收益仍需对照，支持时优先原生 1080p。

Public APIs alone do not establish App Store readiness. The installed development bundle is ad-hoc signed; sandbox operation, distribution signing, privacy disclosures and review remain separate acceptance items.

公开接口不等于已经具备上架资格；当前安装的是临时签名开发包，沙盒运行、发行签名、隐私披露及审核仍须单独验收。

## References / 参考

- Apple WWDC25, Enhance your app with machine-learning-based video effects: https://developer.apple.com/videos/play/wwdc2025/300/
- Apple toolchain / SDK compatibility: https://developer.apple.com/support/xcode/
- Apple Metal drawable lifetime: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html
