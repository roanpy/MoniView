# Distribution and the Mac App Store

## Current artifact

MoniView is built locally with `./Scripts/build-app.sh` as an ad-hoc signed app. It is not signed with a Developer ID and not notarized, and it is not distributed on the Mac App Store, so the current build is not a Store-submittable artifact. Building requires only the Swift toolchain; the Xcode Command Line Tools are enough.

## What is already in place

- `Resources/PrivacyInfo.xcprivacy` is bundled by `Scripts/build-app.sh`. It declares no tracking and no collected data, and lists the required-reason APIs: user defaults (`CA92.1`, appOwnDefaults) and system boot time for elapsed measurement (`35F9.1`).
- `Resources/MoniView.entitlements` is a sandbox entitlement template (app sandbox plus camera, audio input, and user-selected read/write).

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
- `Resources/MoniView.entitlements` 是 sandbox 权限模板（app sandbox 加摄像头、音频输入、用户选择文件读写）。

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

## iOS

未来的 iOS 版本不在本开源仓库中，后续版本可能闭源。已发布版本沿用发布时的许可证。

## 来源

- Apple：[App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)
- Apple：[Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
