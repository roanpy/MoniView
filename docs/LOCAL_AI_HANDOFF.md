# 本地 AI 接手提示词

以下正文可直接发给负责本地 macOS 构建和真实采集卡测试的 AI。它的任务是执行、验证、修复和提交，不是再次只写计划。

---

你接手公开项目 MoniView：https://github.com/roanpy/MoniView 。你在本地 Mac 上工作，可以调用 Apple SDK、运行 app，并配合用户使用真实 UVC 1080p60 采集卡。请先核对实际环境；没有硬件或权限的项目必须明确标为未验证，不能模拟成实测。

## 一、目标和不可改变的边界

把 MoniView 做成画面可信、预览低延迟、性能优先、界面功能简单的小应用。保留底部五个入口和原生菜单风格，不新增复杂控制台。未来需要 Mac/iPad 共用，但这轮先完成 Mac 稳定性验收，不为交差搭空壳 iPad target。

遵守 CONTRIBUTING.md：无第三方运行依赖；中文原文作本地化 key，补齐 en.lproj 对应值并保留格式占位符；不上传设备 ID、序列号、私有路径、完整诊断日志；不虚构截图、画质、延迟、帧率或测试通过。严禁修改 .github/workflows/ 的触发方式，保持仅手动触发。不要复制 OBS/IINA 的 GPL 源码。

## 二、先读取当前代码，再安全集成

外部审查基线是 main 的 e3b6d63f5f6300b0583ee94671246f3de8386ca2，但现在必须以远端实际状态为准。先确认本地 remote 是上述仓库，检查 git status，保护未提交改动和另一位工程师的工作。不 reset --hard、不强推、不覆盖他人分支。

通读当前 README.md、README.zh-CN.md、CONTRIBUTING.md、CHANGELOG.md、docs/REVIEW.md、docs/AI_UPSCALING.md、docs/PLATFORM_BOUNDARIES.md 和 Sources/MoniView 下全部 Swift 文件；新增文件不再只有原来的十个。逐个读取 PR 的当前 diff、评论和 head SHA，不把说明文档当成代码事实。

本批功能 PR：

| PR | 分支 | 内容 |
| --- | --- | --- |
| 1 | codex/audio-duration-buffer | 两秒媒体预算音频 FIFO、背压、尾音排空、计数与清理 |
| 2 | codex/save-current-frame | 文件菜单与 ⌘S 保存当前帧 PNG |
| 3 | codex/always-on-top | 持久化主窗口置顶 |
| 4 | codex/ai-session-lifecycle | AI 重试、会话/资源生命周期、工具链与打包回退 |
| 5 | codex/preview-metrics | GPU 完成计时、帧统计去重与跨屏重绘 |
| 6 | codex/ui-consistency | 分数帧率、实际缓冲格式、本地化和文案 |
| 7 | codex/capture-configuration-revision | 线程安全配置代次及过期错误拦截 |

最后整合 codex/review-handoff 文档 PR。所有功能 PR 独立基于同一旧 main，不是串联分支。先查哪些已经合并；不要重复套用已合并改动。建议顺序 1→2→3→4→5→6→7→文档。

在由最新 main 建立的独立 worktree/集成分支上验证，工作目录不要覆盖当前开发目录。有 gh 可读取 PR；没有 gh 就使用 GitHub 的 pull refs，不要手工复制整个源文件替代合并。

同名文件冲突必须逐段合并：MoniViewApp 同时保留 SaveFrameCommands 和置顶偏好；PreviewLayerView 同时保留 AI 失效逻辑、单帧在飞、计时去重和跨屏重绘；中英文 strings 保留全部新增 key；README 保留录音、PNG、置顶说明及新的测量边界。禁止整文件选择 ours/theirs。集成后先检查 diff 没有修改 workflow 触发或丢掉已有功能。

## 三、先完成真正的构建门禁

外部 AI 做过源码审查、部分 Swift 语法解析及两组纯 Foundation 测试，**没有**完成 Apple SDK 类型检查、macOS 构建、原生 UI/GPU 运行或采集卡实测。你不能沿用“已通过”的说法，必须实际执行：

```sh
swift --version
xcrun --sdk macosx --show-sdk-version
./Scripts/test-audio-buffer.sh
./Scripts/test-configuration-revision.sh
swift build
swift build -c release
./Scripts/build-app.sh
plutil -lint Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
open build/MoniView.app
```

先解决编译错误、并发/Sendable 问题、系统 API 签名或可用性错误，再做交互和性能。以本地 SDK 声明为准，不要编造 Apple API，也不要为了通过构建直接删掉音频缓冲、GPU 资源保活或回退。

实际 AI 路径需要 Apple Swift 6.2+/SDK26+ 构建，以及支持该功能的 macOS26+ 硬件；最低部署版本仍为 macOS14。另验证显式非 AI 回退及其打包，不仅仅测试一条 swift build：

```sh
swift build -Xswiftc -DMONIVIEW_DISABLE_AI
MONIVIEW_DISABLE_AI=1 ./Scripts/build-app.sh
open build/MoniView.app
```

完成后不带环境变量重新打包普通版本。具备条件时再跑 MONIVIEW_ENTITLEMENTS=1 ./Scripts/build-app.sh 验证沙盒保存与权限。不能把 Linux parse 或纯 Swift 测试当作上述门禁的替代。

## 四、真实 UVC 1080p60 验收

### A. 录制音频：最高优先级

确认应用入口与 writer 背压共用同一个约两秒媒体预算 FIFO，超预算丢最旧并计数，累计时长和 PTS 跨度受限，异常小包另有数量上限。无有效 duration 时核对实际 samples/sampleRate，保留真实 PTS，不重排、不用固定偏移伪造同步。

本地建立故障注入/测试夹具，分别让 audio input 短暂不就绪和持续超过预算。确认恢复时先写旧样本，新样本不能越过旧样本；停止时先处理尾部，超时丢弃有计数；开始、成功、失败和下一次录制之间不串音，完成回调恰好一次。普通录制没触发背压，不能算这些分支已覆盖。

用连续讲话/节拍/可见拍手录制并在 QuickTime 回放，检查头尾、长时间音画同步；重复短录、立即停止、停止后重开、录制时退出、无音频、拔出音视频设备、磁盘不足、写入失败和替换已有文件。确认旧文件不因失败而损坏。

检查长时间保留 capture audio buffer 是否导致具体设备的池耗尽、监听中断或内存增长。有证据需要复制时才加入独立 PCM/data 存储；CMSampleBuffer 的浅复制不等于独立音频数据。两秒尾音排空期限不约束 AVAssetWriter 最终 finishWriting 的全部耗时，另观察结束/退出路径。

### B. PNG 与窗口

用菜单和 ⌘S 保存，默认 MoniView-yyyyMMdd-HHmmss.png。必须保存按下命令时的最新完整源帧和设置；不是关掉存储面板时才抓帧。PNG 经 recordedImage 和 pngRepresentation，包含当前色彩与源尺寸锐化，不包含 AI/MetalFX 放大、窗口比例裁切或 UI。

测试饱和度零、亮度变化、信息卡叠层、2K/4K、填满/拉伸模式、录制同时截图、连续 ⌘S、取消、无信号、同名替换和失败提示。用 Preview 检查实际尺寸和色彩。面板长时间停留不能持续占有捕获 buffer，不能阻塞监听与预览。

置顶默认关闭、重启恢复，只设置主预览窗。验证开/关、激活其他普通窗口、全屏进入/退出、全屏中改偏好、进入全屏失败后的恢复、最小化、跨屏以及存储/权限/错误面板；不抢 Space，不给所有 NSApp.windows 一刀切设置 floating。

### C. AI、预览与计时

模型加载期间切换方法、尺寸、增强开关和原始尺寸。旧结果不能重新激活已关闭的配置；一次失败后持续来帧仍能到期重试；最多一个初始化任务；旧池不处理新尺寸。相同尺寸/倍率复用配置本身不是错误。

Metal validation 下检查 Session、参数、CVPixelBuffer、CVMetalTexture 到 GPU 完成的保活，以及 endSession 时序；长时间反复切换观察内存。实际 AI 不可用或没有预算内倍率时应自动回退，不能为了标签显示 AI 而突破处理尺寸上限。

覆盖 720p/1080p、不同显示缩放、跨屏、全屏、最小化、完全遮挡与恢复。单帧在飞和最新帧覆盖策略不能被改成多帧积压。录制/音频不应随预览遮挡而被意外暂停。

计时终点是 GPU 完成回调，不是主线程收尾、屏幕呈现或 HDMI 总延迟。同一采集 sequence 的调参重绘不重复计视频 FPS；真实 HDMI 设备连续发送相同画面仍然是不同 sequence，必须用单帧测试源检查去重分支。不要把新旧计时口径差异当作实际性能提升。

### D. 界面与状态一致性

中英文、最小窗口尺寸分别检查。29.97/59.94 不误亮 30/60；下拉框没有匹配值时不残留旧选择；信息卡显示实际输出 buffer 的 FourCC；简要状态条引擎名称已本地化；2K/4K 表示长边，匹配屏幕不承诺物理像素一一对应；录制期间画质面板说明参数快照已冻结。

反复切换设备/格式/帧率，测试旧配置失败晚于新配置成功的情况；过期回调不能覆盖新状态。使用 Thread Sanitizer 验证代次标记没有跨队列裸读写。查看真实灰阶/色条/细节图，比较原始、MetalFX、AI、PNG 与 MOV，区分处理尺寸/锐化顺序差异和真正偏色。

## 五、只基于证据做下一步优化

先处理可复现的构建失败、崩溃、数据竞争、文件损坏、断音、旧帧、黑屏及偏色，再优化。currentDrawable 可能等待资源；在 Instruments 中测量后，再决定是否调整获取时机或渲染结构。不要直接把 MTKView 搬到后台、把三缓冲改双缓冲、强行替换为 AVAudioEngine、加入插帧/HDR/自动调参或扩大设置面板。

在同一采集源、USB 连接、显示模式、窗口大小、录制状态和处理参数下比较基线与候选。报告真实采集/渲染 FPS、丢帧/丢音、计时分布、GPU 时间、内存趋势和热状态；端到端延迟需外部对照测量。没有实测数字就写未测，不填“预计提升”。

未来 iPad 只先保留共享模型、最新帧、图像处理、录制/导出与平台适配边界。当前 PictureSettings/LatestVideoFrame 仍在 AppKit 的 CaptureManager 文件中，不能声称已经完全跨平台。Mac 稳定后再做真实 iPad 目标，分别验证设备支持、音频路由、触控、前后台、旋转、导出权限和签名，不照搬 macOS API。

## 六、提交与最终报告

有把握的小修复直接完成并回归，不要只告诉我“建议修改”。一个问题或功能一个小 commit，优先回到对应 PR 提交修复；集成分支上的修复也要清楚标注所属 PR，便于回灌，避免维护两套分叉。保护别人的提交，不强推。未明确授权前不要合并 main、发 release 或改签名/工作流策略。

最终交付：实际集成的 PR/commit、每个问题的原因和改动文件、真实执行的命令与通过/失败结果、公开型号/系统/SDK/格式的真机记录、未覆盖的测试和剩余风险。原始诊断只保存在本机，公开报告做脱敏。达到可验收状态后再提出合并顺序与发布建议，不把文档完成等同于验收完成。
