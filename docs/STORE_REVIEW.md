# Review and support guide / 审核与支持步骤

Draft for the final signed build, 2026-10-08. This is an execution checklist, not a runtime acceptance record. No review contact or device credentials are fabricated. / 2026-10-08 最终签名包的操作草稿，不是实测验收记录，不填写虚构联系方式或设备凭据。

## Without capture hardware / 无采集卡审核

1. Launch MoniView with no USB video input attached. Expect no automatically opened camera and no camera permission prompt. The empty-input state and Help → Getting Started are usable. A camera can still be selected explicitly. / 未接 USB 视频输入时启动，不自动打开摄像头或弹摄像头授权；空输入状态和帮助指南可用，摄像头可手动选择。
2. Open an ordinary window in another application containing your own content; leave it open and not minimized. Open MoniView's Capture settings, select Source → Mac window, grant Screen Recording access and choose the window. Refresh/restart if macOS requests it. / 打开其他应用的自有内容窗口，保持打开且不最小化；采集设置 → 画面来源 → Mac 窗口，授权录屏并选窗口；按系统要求刷新／重启。
3. Check live preview and fit/fill options, then switch Natural/Vivid/Cinema color presets. Image enhancement affects preview; optional advanced processing is not required for basic review. / 检查预览与画面比例，切换自然／鲜艳／电影；增强用于预览，基本功能审核无需高级处理。
4. Save a PNG and short MOV to a location selected in the save panel, stop recording and inspect the files. Recordings remain at source resolution; by default they include color and source-resolution sharpening. Disable Record color and sharpening to record the source instead. / 系统保存面板选位置导出 PNG 与短 MOV，停止后查看文件；录制保持源分辨率，默认色彩／锐化，可关闭对应设置。
5. With audio input off, expect silent recordings and no new microphone request. Test a deliberately selected audio input separately. Window capture does not automatically capture another app's audio or select a microphone. / 关闭音频输入时无声录制，不额外请求麦克风；音频另行选择测试，窗口采集不自动录入另一个应用的声音或开启麦克风。
6. Deny Screen Recording access and confirm a recoverable explanation; allow it in System Settings → Privacy & Security, refresh and restart if required. Test camera/microphone denial separately only when those inputs are selected. / 拒绝录屏后应有可恢复说明；系统设置重新允许，按需刷新／重启。摄像头与麦克风拒绝场景在选中相应输入时分别验收。

No sign-in, online service, helper installation or account is required for these app features. Some source apps stop updating when hidden; MoniView cannot supply frames an app stops rendering. / 无需登录、在线服务、安装辅助程序或账号；部分来源应用隐藏后停止更新，MoniView 无法凭空产生源画面。

## Capture-card acceptance / 采集卡验收

Connect a compatible UVC USB capture card to the Mac and an HDMI source to the card. Select the card, grant camera access, choose an advertised format/rate, and test preview. Independently select the card's audio, grant microphone access, and check monitoring and recording. Verify unplug/replug, rejection/recovery of permissions, recording termination/finalization and file failures in the signed sandbox build. / 接入兼容 UVC 卡与 HDMI 来源，授权后选择支持的格式／帧率；独立选择音频，验证监听、录制、拔插、权限恢复、退出收尾和文件错误，均需签名沙盒实测。

If Reviewer hardware is unavailable, the Mac-window path provides basic capture/export review. It does not substitute for capture-card compatibility certification. / 窗口路径可供无卡基本审核，不替代真实采集卡兼容性验收。

## Screenshots / 截图计划

Capture the final signed app in both supported languages with owned media, using real controls and observed values:

1. Window preview and visible local recording controls. / 窗口预览与录制操作。
2. Capture settings and independent audio controls. / 采集设置与独立音频。
3. Color and enhancement panels; no claimed FPS beyond observation. / 色彩与增强面板，不添加虚构帧率。

Use dimensions from [Apple's current screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications). Do not relabel old-build screenshots as final-build evidence, publish personal diagnostics, or use unlicensed game screenshots. Final screenshot files are not supplied in this preparation because no new signed runnable build is being installed. / 按 Apple 当前规格导出；旧构建截图不能冒充最终包，不发布个人日志或无授权游戏画面。本次未安装新签名可运行包，未提供最终截图文件。

## Support and account details / 支持与账号资料

Current feedback: [GitHub Issues](https://github.com/roanpy/MoniView/issues). Include macOS/app version, chosen input type/format, a short reproduction and redacted measurements; omit identifiers, private paths and full logs. / 当前通过 Issues 反馈，提供版本、格式、复现与脱敏测量，不提供设备标识、私有路径或完整日志。

Before submission, the owner must supply genuine support contact information on the public support page and real App Review contact details in App Store Connect. No contact address, legal identity, price, age rating or encryption answer has been invented or submitted. The public privacy URL must serve the approved final policy. / 提交前由所有者补公开支持页真实联系方式及审核联系人；本轮未编造或提交联系地址、法律主体、价格、分级或加密答案，隐私地址须发布批准的最终政策。
