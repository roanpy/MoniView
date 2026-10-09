# Paid App Store direction / App Store 付费方向

Research checked on 2026-10-06. This is a proposal, not approval, an uploaded build or an accepted agreement. / 2026-10-06 核查；这是方案，不是审核通过、上传记录或协议签署。

## Recommendation / 建议

Offer a simple one-time paid download, provisionally US $0.99, with no subscription or in-app purchase added for the initial app. Apple's published USD grid includes $0.99 and $1.00; select the actual available price in App Store Connect. Regional prices may vary with taxes and exchange rates. / 首版建议美区 $0.99 一次性购买，不增加订阅或内购。Apple 公布的美元价格表包含 $0.99 和 $1.00，最终以 App Store Connect 实际可选档位为准；地区价格受税费及汇率影响。

Developer Program membership is US $99 per year (regional pricing may differ). Paid distribution also requires the applicable paid-app agreement, banking and tax information. Qualifying developers enrolled in the Small Business Program receive its 15% commission rate; eligibility and the account's actual agreements must be checked. / 开发者会员通常每年 $99，地区定价可能不同；收费发行还需相关付费协议、银行与税务资料。符合资格并加入小企业计划后适用其 15% 佣金，不能默认账户已具备资格。

The current repository notice reserves all rights; public source visibility does not grant use or redistribution permission. The copyright holder may separately license an App Store build. Third-party code, models and assets require separate license checks. Earlier MIT releases keep their granted rights; the new notice cannot revoke them. / 当前仓库声明保留所有权利，公开源码不授予使用或再分发许可；著作权人可另行授权 App Store 构建。第三方代码、模型及素材须分别核查。早期 MIT 版本保留既有授权，新声明不能撤销。

## Performance and API boundary / 性能与 API 边界

Sustained 120 FPS is not certified. A strict synthetic native-window run met its actual-presentation throughput/spacing checks on the tested Mac; this does not certify every scene, target or real capture device. Do not advertise guaranteed sustained 120 FPS from that limited test or GPU command timing alone. The interpolation implementation uses documented Apple public APIs, but API research or public availability is not App Review approval or performance certification. This remains a macOS distribution proposal: no paid agreement, store submission, iPad target or iPad acceptance is complete. / 持续 120 FPS 尚未认证。本机一次合成原生窗口 strict 测试通过了实际呈现吞吐与间隔检查，但不能认证所有场景、目标及真实采集设备，也不能仅凭 GPU 耗时宣传保证持续 120 帧。插帧实现基于 Apple 文档化的公开 API，但公开 API 的研究或可用不等于 App Store 审核通过或性能认证。本文件仍是 macOS 发行方案：付费协议、商店提交、iPad target 与 iPad 验收均未完成。

## Before submission / 提交前

- Build/archive/sign with the required Apple distribution toolchain and account; this project's locally signed development bundle is not a store submission. An external build system is supported; distribution packaging/signing still needs Apple's tools and the appropriate account. / 使用符合当期要求的 Apple 工具链和发行账号归档签名，本地开发签名包不是商店提交包；允许使用外部构建系统，但分发签名与打包仍需 Apple 工具及相关账号。
- Validate the sandbox configuration with actual USB video/audio, device reconnect, recording, selected-file access, PNG export and quit/error cleanup. Existing entitlements alone are not proof of acceptance. / 真机验收沙盒下 USB 音视频、重连、录制、用户选定文件、PNG 及退出/错误清理；已有 entitlement 不等于验收完成。
- Review the drafted privacy declarations, bilingual metadata and hardware-free review instructions in [APP_STORE.md](APP_STORE.md); publish approved support/privacy pages with real contact details and capture final screenshots before submission. / 本轮已准备隐私说明、双语文案与无卡审核步骤；提交前仍须发布批准的支持／隐私页、补真实联系方式并拍摄最终截图。
- Describe actual capture, scaling and generated FPS separately. Do not promise native 4K capture, universal AI improvement, lower HDMI latency, sustained 120 FPS (not certified) or iPad support that was not tested. Experimental interpolation should not be the initial paid version's guaranteed selling point. / 分开描述真实采集、放大和生成帧率；不承诺未经验证的原生 4K、普遍 AI 收益、总延迟降低、尚未认证的持续 120 帧或未实测的 iPad 支持。实验性插帧暂不作为首版保证卖点。

No App Store account changes, legal agreements, purchases or submission were performed by this work. / 本轮未修改商店账户、签署协议、付费或提交审核。

## Sources / 来源

- [Apple pricing](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price), [published price grid](https://www.apple.com/newsroom/pdfs/App-Store-Pricing-Update.pdf)
- [Membership](https://developer.apple.com/programs/enroll/), [Small Business Program](https://developer.apple.com/app-store/small-business-program/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [project license](../LICENSE)

## Non-signing preparation — 2026-10-08 / 非签名准备

Source changes and a separate preparation bundle are complete; no certificate, profile, signing, account, upload or installed-app change was performed. Sandboxed hardware acceptance and final screenshots are pending. See [preparation status](APP_STORE.md) and [review steps](STORE_REVIEW.md). / 已完成代码与独立准备包，未处理证书、profile、签名、账号、上传或替换已安装应用；沙盒真机验收和最终截图待完成。
