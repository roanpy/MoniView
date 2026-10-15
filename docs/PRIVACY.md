# Privacy / 隐私说明

Updated: 2026-10-08. Applies to the current source code; a distribution build must be checked against this policy before submission. / 更新于 2026-10-08；适用于当前代码，提交前仍需核对实际发行包。

## English

MoniView processes video and audio locally. It has no account system, advertising, analytics, telemetry or automatic uploads. Its bundled privacy manifest declares no tracking and no collected data. Local processing and storage are distinct from collecting data off the device.

### Permissions

- **Camera:** reads the selected UVC video capture card or a manually selected camera. Without an eligible USB video input, startup neither selects a camera nor requests camera permission. Selecting a camera manually requests permission when needed. A connected eligible USB video input may be selected automatically; AVFoundation can also classify a USB camera as such an input.
- **Microphone:** reads the selected audio input for live monitoring and recording. Audio can be selected independently; a previously chosen input can be restored, and a capture card's matching audio may be paired automatically. Turn audio input off to use video and silent recordings without microphone access.
- **Screen Recording:** ScreenCaptureKit reads the Mac window you select for local preview and optional recording. Only the Mac-window source needs this permission; it does not automatically select a microphone.

macOS permission names also apply to capture cards. Permission can be changed in System Settings → Privacy & Security. Refresh devices/windows afterwards; macOS may require restarting the app. No capture device is needed to read the offline Getting Started guide in the Help menu.

### Local storage

- Recordings and PNG snapshots are written to the location you choose in the system save panel. Captured pixels/audio are otherwise processed in memory.
- Settings include picture preferences and device identifiers used to restore an input and its format. These identifiers stay in local user defaults; MoniView does not send them to the developer.
- A periodically replaced diagnostic snapshot contains device/audio names, resolution, frame rates, pixel format and processing/presentation timing. It is stored in the user Library at `Logs/MoniView/diagnostics.json`. In the ordinary development build this is `~/Library/Logs/MoniView/diagnostics.json`; Foundation resolves Library inside the app container when App Sandbox is enabled. Sandboxed runtime validation remains pending.
- Settings and diagnostics remain local. Deleting a recording/snapshot removes that exported file. Uninstalling the app does not necessarily remove exports, settings or diagnostics; remove these separately if desired. Diagnostics may be recreated while the app is running.

### Links and voluntary feedback

Help links open your system browser on GitHub. The app itself does not upload captured media or diagnostics. GitHub and your browser handle their own network requests and privacy practices. If you voluntarily submit a public issue, its contents are public and handled by GitHub.

Do not attach device identifiers, serial numbers, private paths, personal media or full diagnostic logs to public issues. Prefer a short description and redacted measurements. The current issue channel is [GitHub Issues](https://github.com/roanpy/MoniView/issues).

## 简体中文

MoniView 在本机处理音视频，没有账号系统、广告、分析、遥测或自动上传。打包的隐私清单声明不跟踪、不收集数据。本机处理和保存与向设备外收集数据不同。

### 权限

- **摄像头：**读取选中的 UVC 视频采集卡或手动选择的摄像头。没有符合条件的 USB 视频输入时，启动既不自动选择摄像头，也不请求摄像头权限。手动选择摄像头后按需请求权限；符合条件的 USB 视频输入可能自动选中，AVFoundation 也可能将 USB 摄像头归入此类输入。
- **麦克风：**读取所选音频输入，用于监听和录制。音频可独立选择，之前选择的输入可恢复，采集卡同名音频也可能自动配对。关闭音频输入后，可使用视频与无声录制而无需麦克风权限。
- **屏幕录制：**通过 ScreenCaptureKit 读取你选中的 Mac 窗口，用于本地预览与可选录制。只有 Mac 窗口来源需要此权限，不会因此自动选择麦克风。

系统的摄像头／麦克风权限名称也适用于采集卡。可在系统设置 → 隐私与安全性中修改权限，之后刷新设备／窗口；系统可能要求重启应用。帮助菜单中的离线使用指南无需连接采集卡。

### 本机存储

- 录制和 PNG 截图保存到系统保存面板选定的位置；未请求保存时，捕获的像素与音频在内存中处理。
- 设置包括画面偏好，以及恢复输入与格式所需的设备标识。设备标识保存在本机用户偏好中，不发送给开发者。
- 定期替换的诊断快照包含视频／音频设备名、分辨率、帧率、像素格式与处理／呈现耗时，位于用户 Library 下的 `Logs/MoniView/diagnostics.json`。普通开发版对应 `~/Library/Logs/MoniView/diagnostics.json`；启用 App Sandbox 时 Foundation 会将 Library 定位到应用容器内。沙盒运行实测尚待完成。
- 设置与诊断留在本机。删除录制／截图文件即删除该导出文件；卸载应用不一定删除导出文件、设置和诊断，需要时请分别删除。应用运行期间可能重新生成诊断。

### 链接与主动反馈

帮助链接通过系统浏览器打开 GitHub，应用自身不上传捕获媒体或诊断。GitHub 与浏览器的网络请求适用各自隐私规则。主动提交公开 issue 时，所填写内容会公开并由 GitHub 处理。

公开 issue 请勿附上设备标识、序列号、私有路径、个人媒体或完整日志，建议只提供简短说明与脱敏测量。当前反馈入口：[GitHub Issues](https://github.com/roanpy/MoniView/issues)。
