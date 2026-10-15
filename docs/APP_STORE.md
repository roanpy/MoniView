# Mac App Store preparation / Mac App Store 准备

Checked against Apple documentation on 2026-10-08. This is preparation, not submission or App Review approval. / 2026-10-08 核查；本页说明准备状态，不代表提交或审核通过。

## Completed without distribution signing / 已完成的非签名准备

- Native SwiftPM app using Apple frameworks and project Metal code; no third-party runtime helper/model to install. / 原生 SwiftPM 与 Apple 框架、自研 Metal，无需安装第三方运行辅助程序／模型。
- Camera permission is requested only for an actual selected video input; no automatic camera selection or camera prompt when no eligible USB video input is present. Manual camera selection remains available. / 选中实际视频输入后才请求权限；没有符合条件的 USB 视频输入时不自动选摄像头或请求权限，保留手动选择。
- English/Simplified Chinese permission descriptions, offline Help → Getting Started, privacy-policy link and support link. / 中英文权限说明、离线使用指南、隐私政策与反馈入口。
- Privacy manifest bundled: no tracking/collected data; app-owned defaults `CA92.1`, elapsed-time measurement `35F9.1`. [Privacy policy](PRIVACY.md) explains local device identifiers, diagnostics and voluntary GitHub feedback. / 隐私清单随包，本机标识、诊断及主动反馈在隐私说明中列明。
- Foundation resolves diagnostic storage through the user Library; PNG/MOV use system save panels, security-scoped access and same-volume recording staging. No remembered export directory requiring a bookmark. / Foundation 定位 Library，系统保存面板与安全作用域访问，录制使用目标卷暂存，不跨启动记忆导出目录。
- [Bilingual metadata](STORE_METADATA.json) and [review/support instructions](STORE_REVIEW.md) drafted. Length limits checked during preparation; account details and screenshot capture remain pending. / 已拟定双语文案、审核／支持步骤，准备时核对字段长度；账号信息和截图尚待补齐。

## Build without signing / 不签名的准备包

```sh
MONIVIEW_PREPARE_ONLY=1 MONIVIEW_BUILD=117 ./Scripts/build-app.sh
```

Stages `build/store-preparation/MoniView.app`, compiles Release and checks bundled plist/localization resources. Does not invoke codesign, unlock a keychain, install, enable the sandbox or upload. The linker may provide its own executable signature; this is not a distribution signature. It leaves `build/MoniView.app` and the installed app untouched. Do not distribute or claim sandbox acceptance from this artifact. / 生成独立准备包，Release 编译并校验资源；不调用签名工具、不解锁钥匙串、不安装、不启用沙盒、不上传。链接器自身可能包含可执行文件签名，但不是发行签名；现有普通构建与已安装 app 不受影响。不可将准备包当作发行包或沙盒验收结果。

The normal build script still defaults to ad-hoc signing and accepts an explicit local identity. The installed local build 116 was self-signed for development without App Sandbox; it is not a Store package. Developer ID signing/notarization is a separate outside-Store route, not a prerequisite for the Mac App Store route. / 普通构建仍默认 ad-hoc，可显式指定本地身份；已安装 116 是未启用沙盒的本地开发自签名，不是商店包。Developer ID／公证属于商店外发行路线，不是 Mac App Store 上架的前置条件。

## Deferred until signing is authorized / 签名后再完成

- [ ] Account, final bundle identifier, distribution identity and any required provisioning profile. Mac apps without restricted entitlements may not need a profile for App Store distribution; TestFlight always requires one. / 账号、最终 bundle ID、分发身份与需要的 profile；没有受限 entitlement 的 Mac 商店应用可能无需 profile，TestFlight 则始终需要。
- [ ] Apply and inspect signed sandbox entitlements. Template includes app sandbox, camera, sandbox microphone, hardened-runtime audio input and user-selected read/write; no unsupported screen-capture entitlement. ScreenCaptureKit requires user Screen Recording permission. / 实际应用并核对签名的沙盒权限；模板不是运行证明，窗口采集需系统录屏授权。
- [ ] Run signed sandbox hardware acceptance: USB video/audio, reconnect, no-device startup, permission denial/recovery, Mac window capture, recording overwrite/error/finalization, PNG export and quit cleanup. / 签名沙盒下验收上述真机和文件场景。
- [ ] Package through Apple's distribution tools and validate/upload. An external build system is supported; an Xcode project rewrite is not inherently required. Verify the final package has no quarantine attributes. / 使用 Apple 工具打包、验证与上传；可使用外部构建系统，不必为了上架重写 Xcode 工程；核查最终包无 quarantine 属性。

## Content and release checks / 内容与发行检查

- [ ] Owner supplies real support contact and App Review contact, copyright holder, price, territories, age-rating and applicable agreement answers. GitHub Issues alone does not supply all required contact details. / 由所有者提供真实支持／审核联系方式、版权主体、价格、地区、分级与相关协议信息；Issues 本身不足以补齐联系信息。
- [ ] Merge or publish approved support/privacy changes at stable URLs before submission; a draft PR does not update the existing main-branch policy URL. / 提交前合入或发布批准的政策／支持页；草稿 PR 不会更新 main 链接。
- [ ] Take actual final-build English/Chinese screenshots using owned content; do not reuse game screenshots without rights. / 用有权使用的内容拍摄最终构建中英文截图。
- [ ] Verify user-visible recording indication and remove unsupported marketing promises. Interpolation is optional/experimental; do not promise sustained 120 FPS, arbitrary variable input fixed at 60, lower HDMI latency, neural MetalFX or an iPad version. / 保留明确录制指示，不宣传未经认证的 120、任意变帧恒 60、HDMI 延迟收益、神经 MetalFX 或 iPad。
- [ ] Finish App Privacy answers against the actual submitted binary. On-device processing is not off-device collection; review again if telemetry, SDKs or upload features are introduced. / 按实际提交包填写隐私答案；本机处理不是设备外收集，新增遥测／SDK／上传后需重审。

Apple requires sandboxing and accurate, complete reviewable apps. Experimental feature acceptance should use TestFlight; simply removing “Beta” from a label is not certification. iPad development is a separate future target, outside this preparation. / Apple 要求沙盒与准确、完整、可审核的应用；实验功能先做 TestFlight 验收，改名称不能证明稳定。iPad 为独立后续目标。

## Sources / 官方依据

- [Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Distribution signing with external build systems](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [Mac packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution), [TN3125 provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/), [metadata fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information), [screenshots](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
