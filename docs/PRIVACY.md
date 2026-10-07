# Privacy

MoniView is a local macOS app. It has no account system, no analytics, no telemetry, and no network transmission. The app bundles a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no collected data.

## Permissions required

- **Camera**: reads the USB (UVC) capture card video.
- **Microphone**: reads the capture card's audio input for live monitoring and recording. This permission is optional: set the audio input to off and video preview and silent recording still work.
- **Screen Recording**: captures the Mac window you select for local preview, enhancement and optional recording through ScreenCaptureKit. This permission is needed only for the Mac-window source.

Camera access is required for capture-device video, not Mac-window preview. Microphone access is needed only when you select an audio input for monitoring or recording; Mac-window capture does not enable a microphone automatically.

## Data handled locally

- **Recordings**: written only to the file you choose in the save panel.
- **Settings**: stored locally in the app's user defaults on this machine.
- **Diagnostics**: written to `~/Library/Logs/MoniView/diagnostics.json`, containing device and audio device names, resolution, frame rate, pixel format, and timing. It stays on the machine.
- In a sandboxed build, settings and diagnostics are stored within the app's sandbox container. Captured window pixels are processed in memory and are saved only when you request a recording or snapshot.

MoniView does not collect capture card serial numbers or personal identifiers, does not upload anything to an external service, and does not send data to the developer.

## Sharing issue reports

Do not attach capture card serial numbers, device identifiers, private file paths, or full diagnostic logs to public issues. The diagnostics file contains device names that can identify your hardware.

---

# 隐私说明

MoniView 是本机运行的 macOS app，没有账号系统、没有统计分析、没有遥测，也不进行任何网络传输。app 打包了隐私清单（`PrivacyInfo.xcprivacy`），声明不跟踪、不收集数据。

## 权限

- **摄像头**：读取 USB（UVC）采集卡的视频。
- **麦克风**：读取采集卡的音频输入，用于实时监听和录制。该权限可选：将音频输入设为关闭后，视频预览与无声录制仍可正常使用。
- **屏幕录制**：通过 ScreenCaptureKit 捕获你选择的 Mac 窗口，用于本地预览、增强及可选录制；仅本机窗口来源需要此权限。

采集设备的视频预览需要摄像头权限，本机窗口预览不需要。选择音频输入用于监听或录制时才需要麦克风权限；选择本机窗口不会自动开启麦克风。

## 仅在本机处理的数据

- **录制文件**：只写入你在存储面板中选择的文件。
- **设置**：保存在本机 app 的用户偏好中。
- **诊断信息**：写入 `~/Library/Logs/MoniView/diagnostics.json`，包含设备名和音频设备名、分辨率、帧率、像素格式和耗时数据，只留在本机。
- 沙盒构建的设置和诊断保存在应用容器内。窗口像素在内存中处理，只有你请求录制或保存截图时才写入文件。

MoniView 不收集采集卡序列号或个人身份信息，不向外部服务上传任何内容，也不向开发者发送数据。

## 提交 issue 时的注意事项

请勿在公开 issue 中附加采集卡序列号、设备标识、本机私有路径或完整诊断日志。诊断文件包含可能识别你硬件的设备名称。
