# Distribution and the Mac App Store

## Current artifact

MoniView is built locally with `./Scripts/build-app.sh` as an ad-hoc signed app. It is not signed with a Developer ID and not notarized, and it is not distributed on the Mac App Store, so the current build is not a Store-submittable artifact. Building requires only the Swift toolchain; the Xcode Command Line Tools are enough.

## What is already in place

- `Resources/PrivacyInfo.xcprivacy` is bundled by `Scripts/build-app.sh`. It declares no tracking and no collected data, and lists the required-reason APIs: user defaults (`CA92.1`, appOwnDefaults) and system boot time for elapsed measurement (`35F9.1`).
- `Resources/MoniView.entitlements` is a sandbox entitlement template (app sandbox plus camera, sandbox microphone, hardened-runtime audio input, and user-selected read/write). ScreenCaptureKit still requires the user's Screen Recording permission; it does not use the unsupported `com.apple.security.screen-capture` entitlement.

The normal developer build does not sign with those entitlements and does not enable the sandbox; it stays ad-hoc. Sandboxed capture-card behavior has not been tested on Store hardware.

`Scripts/build-app.sh` accepts overrides so the same script produces both kinds of artifact. The default invocation is unchanged. To verify the sandbox path, sign with the bundled entitlements and hardened runtime:

```sh
MONIVIEW_ENTITLEMENTS=1 ./Scripts/build-app.sh
```

The script also accepts `MONIVIEW_VERSION`, `MONIVIEW_BUILD`, `MONIVIEW_ARCH`, and `MONIVIEW_SIGN_IDENTITY`, verifies the signed bundle, checks the bundled resources, and prints the architecture and version. A Store or notarized artifact still needs a real signing identity and, for the Store, a provisioning profile; the sandbox flag alone does not make a submittable build.

## Checklist for a future Store submission

This is not complete today. Each item needs to be finished and verified on real hardware before a submission is claimed to be ready.

- [ ] Apple Developer Program membership and an App Store distribution certificate.
- [ ] Apply `Resources/MoniView.entitlements`, enable the hardened runtime, and verify capture, audio, and recording under the sandbox on real hardware.
- [ ] Confirm the bundled privacy manifest and entitlements are correct for the submitted build.
- [ ] Store metadata, screenshots, and a privacy policy URL.
- [ ] App Review validation on real hardware.

## Code review update — 2026-10-07

- Removed the unsupported screen-capture entitlement and added the documented sandbox microphone entitlement. The existing audio-input entitlement remains for hardened runtime. This corrects the template; it is not proof that capture works in a sandboxed release.
- Recording and PNG export already use `NSSavePanel`; validate writing after panel dismissal, recording finalization, and disk errors under the sandbox. If a destination is remembered across launches, add a security-scoped bookmark and handle revoked access then; the current app does not remember an export destination.
- MOV staging now uses Foundation's `itemReplacementDirectory` on the selected destination's volume, with a security-scoped-access lifetime through finalization. The development fault suite passes overwrite preservation, commit failure, reuse and staging cleanup; sandboxed runtime and other-volume behavior remain to be tested.
- The production target uses Apple frameworks and its own Metal flow code, without a Python/ffmpeg helper or bundled RIFE model. Test scripts are developer tools, not installed app dependencies. Any future model needs its own weight-license and redistribution review.
- Store packaging needs Apple distribution signing, the matching profile and an Xcode-supported archive/upload workflow. The local self-signed identity and this shell-built development bundle do not satisfy that workflow. No launchd job or environment variables should be required for normal app use.
- Confirm privacy-manifest reasons against actual usage, local diagnostic storage inside the sandbox container, localized permission text, support/privacy URLs and a visible recording indicator. Prepare a reviewer path using Mac window capture, so basic functionality can be reviewed without an external capture card.
- Stabilize experimental interpolation before a public Store release; use TestFlight for beta acceptance. Removing the word “Beta” alone does not establish stability. Advertise generated FPS separately from input FPS and do not promise sustained 120 or fixed 60 across arbitrary input rates until those cases pass.

References: [sandbox microphone](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone), [audio input](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input), [Apple DTS on the unsupported entitlement](https://developer.apple.com/forums/thread/778616), [Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## iOS

A future iOS version is not part of this open-source repository, and later versions may be closed source. Existing releases keep the license they shipped with.

## Sources

- Apple: [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)
- Apple: [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

---

# 分发与 Mac App Store

## 当前产物

MoniView 通过 `./Scripts/build-app.sh` 在本机构建，是 ad-hoc 签名的 app。它没有 Developer ID 签名，未做公证，也不通过 Mac App Store 分发，因此当前构建不是可提交到 Store 的产物。构建只需要 Swift 工具链，Xcode Command Line Tools 即可。

## 当前已具备

- `Resources/PrivacyInfo.xcprivacy` 由 `Scripts/build-app.sh` 打包进 app。它声明不跟踪、不收集数据，并列出 required reason API：用户偏好（`CA92.1`，appOwnDefaults）与用于耗时测量的系统启动时间（`35F9.1`）。
- `Resources/MoniView.entitlements` 是 sandbox 权限模板（沙盒、摄像头、沙盒麦克风、hardened runtime 音频输入、用户选择文件读写）。ScreenCaptureKit 仍需用户授予系统录屏权限，不使用无效的 `com.apple.security.screen-capture` entitlement。

普通开发构建不使用这些 entitlements 签名，也不启用 sandbox，保持 ad-hoc。沙盒下的采集卡行为尚未在 Store 硬件上实测。

`Scripts/build-app.sh` 支持覆盖参数，同一个脚本既能产出开发构建，也能产出用于沙盒验证的构建。默认调用方式保持不变。要验证沙盒路径，用打包内的 entitlements 与 hardened runtime 签名：

```sh
MONIVIEW_ENTITLEMENTS=1 ./Scripts/build-app.sh
```

脚本还接受 `MONIVIEW_VERSION`、`MONIVIEW_BUILD`、`MONIVIEW_ARCH`、`MONIVIEW_SIGN_IDENTITY`，会校验签名结果、检查打包资源，并输出架构与版本。真正上架或公证仍需要正式的签名身份，上架还需要 provisioning profile；只加沙盒标志并不等于可提交产物。

## 未来上架 Store 的清单

以下内容目前尚未完成。在宣称可提交之前，每一项都需要完成并在真实硬件上验证。

- [ ] Apple Developer Program 会员资格与 App Store 分发证书。
- [ ] 应用 `Resources/MoniView.entitlements`，启用 hardened runtime，并在沙盒下于真实硬件验证采集、音频和录制。
- [ ] 确认打包的隐私清单与 entitlements 适用于提交的构建。
- [ ] Store 元数据、截图和隐私政策链接。
- [ ] 在真实硬件上通过 App Review 验证。

## 2026-10-07 代码核查补充

已修正权限模板：补上沙盒麦克风权限，移除无效的屏幕采集 entitlement，保留 hardened runtime 的音频输入权限。尚未完成签名发行包的沙盒真机验收。

录制与 PNG 已使用系统保存面板；MOV 已改用 Foundation 在目标卷上提供的替换临时目录，并维持安全作用域访问到收尾结束。开发态故障测试通过覆盖保护、提交失败、重用和临时目录清理；沙盒实测和其他卷仍待验证。当前不跨启动记忆导出目录，因此暂不需要目录书签；今后若增加记忆目录，需要安全作用域书签与权限失效恢复。

当前应用使用 Apple 框架与自研 Metal 光流，没有运行 Python/ffmpeg 或打包 RIFE 模型。测试脚本不属于用户运行依赖。上架需正式分发证书、匹配 profile 和 Xcode 支持的归档／上传流程；本地自签名不能用于商店提交，普通用户运行也不应依赖 launchd 或环境变量。

其余准备：核对隐私清单和容器内日志、中英文权限说明、支持／隐私链接、明确录制指示；提供无需采集卡的窗口采集审核步骤。实验插帧先在 TestFlight 验收，不能仅改掉 Beta 名称就宣称稳定。不宣传未经实测的持续 120 或任意输入固定 60。

## iOS

未来的 iOS 版本不在本开源仓库中，后续版本可能闭源。已发布版本沿用发布时的许可证。

## 来源

- Apple：[App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)
- Apple：[Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
