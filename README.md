# DJOneHub for iOS

> 把大疆第一代 4G 模块接到 iPhone，在手机上使用模块中的 SIM 接打电话、查看短信。

DJOneHub 是一个围绕 QDC507 模块开发的非官方项目。iOS App 通过 USB 网络直接与模块通信，电话控制和双向语音都在 iPhone 与模块之间完成，通话期间不需要 Mac 中转。

项目目标是：**首次用 Mac 完成模块配置，之后只用 iPhone。** 当前已完成 iPhone 通话闭环，模块提醒和长期授权正在逐步接入；首次部署及现有开发配对的维护仍需要 Mac。

## 已经做到了什么

### 在 iPhone 上接打电话

- 拨号、接听、拒接和挂断，提供全屏来电与通话界面。
- iPhone 内置麦克风与扬声器承载双向语音，无需手动启动音频探针。
- 拨号和接听时自动预热音频；接通前不发送麦克风内容，接通后开启双向语音。
- 支持上行静音、本地通话录音及自动录音选项，录音关联到通话记录。
- 提供最近通话、通讯录、拨号键盘和信息四个主入口。

**已有真机验证：** 主动拨号、来电接听与拒接、双向语音、连续重拨、通话中切换到其他 App、锁屏与解锁后持续通话，以及模块拔插后的重新连接。

当前音频使用内置麦克风和扬声器。听筒、扬声器与蓝牙耳机的主动切换尚未完成，不能把“蓝牙连接不影响通话”理解为“已支持通过蓝牙耳机通话”。

### 断线后重新连接

App 会自动恢复已保存的开发配对并读取模块状态。模块断开后停止旧音频会话，重新上电后重新认证并读取真实通话状态，不沿用断开前的通话画面或音频会话。

已完成断线识别和重连回归；首次连接与模块冷启动仍有等待时间，进一步提速见[连接优化计划](docs/ios-module-connection-speed-plan.md)。模块拔线导致断电时，不保证原有电话继续保持。

### 在手机上查看模块短信

“信息”页通过独立的短信网关读取 SIM 与模块存储中的短信，支持前台自动刷新、正文解析、未读提示和详情查看。

**当前 iOS 页面只读。** 短信发送与删除虽然已有底层协议，尚未作为可用功能开放；长短信处理和更多运营商场景也需要继续验证。

### 模块自主发送来电、短信提醒

模块端已实现 Bark 提醒，以及直接发送 Web Push 的实验路径。提醒任务运行在模块上，不要求 Mac 常驻或 DJOneHub App 一直处于前台。

在 iOS 的模块提醒页面中，可以：

- 配置自己的 HTTPS Bark 服务地址，并发送测试提醒。
- 分别选择来电是否显示号码、短信通知是否显示正文。
- 设置来电提醒声音，停用 Bark，查看脱敏后的服务状态。
- 导入自托管服务使用的 CA 证书。
- 导入 Web Push 订阅文件并发起测试。

这套方案**不需要维护 DJOneHub 通知中转服务器**。Bark 仍使用用户选择的推送服务；Web Push 仍依赖浏览器推送服务及一个 HTTPS 静态订阅页面。模块和手机都需要联网。

默认提醒不包含来电号码和短信正文；启用相应选项后，这些内容会交给所选推送服务。普通通知用于提醒用户打开 App，**不等于 App 被终止后可以自动唤醒并锁屏接听**。Bark 的更多实际使用场景及 Web Push 的 iPhone 完整收件验证仍需补齐。

详见[模块提醒的配置、投递行为与验证范围](docs/module-notifications.md)。

## 当前状态

| 能力 | 进展 |
| --- | --- |
| iPhone 拨号、接听、拒接、挂断与双向语音 | 已完成真机闭环 |
| 已建立通话的后台音频、锁屏持续通话 | 已完成基线真机验证，更多中断和长时间压力场景待补充 |
| 断线停止音频、模块重启后自动重连 | 已完成真机回归 |
| 通话记录、通讯录、静音、本地录音 | 已实现 |
| 短信收件与查看 | 已接入只读页面；发送、删除尚未开放 |
| Bark 与 iOS 提醒配置 | 已实现，更多真机投递场景待验证 |
| 模块直发 Web Push | 实验功能，完整端到端验收待完成 |
| 听筒／扬声器／蓝牙耳机切换 | 已制定计划，待实施 |
| 模块长期授权、恢复换机与撤销 | 授权核心和 iOS 客户端已实现，尚未替换旧通话配对 |
| App 被挂起或终止后的系统级来电唤醒 | 尚未完成可靠闭环 |
| 面向普通用户的首次配置向导 | 尚未完成 |

CallKit／PushKit 已有接入代码，不能据此承诺系统电话级的后台来电能力。本文中的“后台通话”指已经接通后的音频持续运行。

## 如何开始

目前提供源码构建和开发部署流程，尚未形成面向普通用户的一键安装体验。

### 准备设备

- 大疆第一代 4G 模块；当前实现和验证围绕 **QDC507**，其他型号或固件不保证兼容。
- 可用的实体 SIM，以及支持当前模块语音业务的运营商网络。
- 能通过 USB 数据连接模块的 iPhone、数据线及稳定供电。
- 用于首次模块部署和 iOS App 构建签名的 Mac。

iOS 工程最低部署版本为 **iOS 17.0**；这不代表所有系统版本、iPhone 或转接器组合均已验证。

### 首次配置与使用

1. **先准备模块。** 使用开发部署流程安装匹配版本的电话、短信、音频和可选提醒服务，并配置适合 iPhone 的 USB 网络模式。当前通话方案关闭模块 USB Audio，使用 USB 网络传输语音。
2. **构建并安装 iOS App。** 在 Xcode 打开下面的工程，选择 `DJOneHub` scheme，为真机配置签名团队。
3. **导入开发控制配对。** 将该模块的 CONTROL 配对文件导入 App，再把模块换接到 iPhone。STATUS 只读配对不能用于拨号。
4. **等待“可以拨号”。** 授予麦克风权限；使用通讯录时按需授予联系人权限，然后测试拨号和接听。
5. **按需开启提醒。** 在模块提醒页面配置 Bark 或导入 Web Push 订阅，发送测试并确认手机实际收到。

模块准备会安装运行组件和启动配置，不是仅安装一个 iOS App 即可使用。详细部署与诊断见 [iOS 工程说明](ios/DJOneHubUACProbe/README.md)；其中 UAC Probe、STATUS 一次性测试等章节是开发诊断流程。

### 构建 iOS App

```sh
open ios/DJOneHubUACProbe/DJOneHubUACProbe.xcodeproj
```

工程包含两个 target：

| Target | 用途 |
| --- | --- |
| `DJOneHub` | 日常通话 App，本文介绍的 iOS 成果 |
| `DJOneHubUACProbe` | USB Audio、网络和协议诊断工具 |

当前开发配置下，两个 target 沿用同一 bundle ID，不适合同时安装。真机运行需要在 Xcode 中配置自己的签名。

仅检查模拟器构建，可在仓库根目录执行：

```sh
xcodebuild \
  -project ios/DJOneHubUACProbe/DJOneHubUACProbe.xcodeproj \
  -scheme DJOneHub \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

模拟器可以用于编译检查，不能代替真实模块的 USB 连接和通话测试。

## 距离“以后完全不接 Mac”还有多远

已部署的模块可以换接 iPhone 后完成日常通话；提醒服务也能在模块上独立运行。**但当前通话使用的开发配对仍有 30 天期限**，换手机、撤销和恢复流程尚未全面产品化。

新授权方案已实现独立模块身份、一次性绑定码、长期手机凭据、TLS 加密管理、恢复码换机和模块端撤销。iPhone 会先保存新凭据，再确认绑定生效，以支持中断后重试。

这一方案目前默认关闭，还没有接入用户页面，也没有统一替代通话、短信、音频和提醒的旧授权。因此，新授权服务中的撤销不能代表旧通话密钥已失效。完成统一授权与实机验证后，才会接入首次配置向导。

详见[长期授权实现状态与迁移条件](docs/module-authorization-lifecycle.md)。

## 工作原理

```text
iPhone · DJOneHub
    │
    │ USB ECM 本地网络
    │ 电话控制 / 双向 PCM / 短信读取 / 提醒配置
    ▼
QDC507 模块 ── SIM / 蜂窝网络 ── 电话与短信
    │
    └── 模块提醒服务 ── Bark 或 Web Push ── 手机通知
```

电话控制与媒体在本地 USB 链路上传输，Mac 不参与日常通话的数据转发。现有控制协议采用 HMAC 认证，**认证不等于传输加密**；新 TLS 授权管理通道尚未覆盖全部旧协议。

本地录音保存为 WAV 文件。配对凭据使用 iPhone Keychain 保存；恢复资料、Bark 地址中的设备密钥和 Web Push 订阅文件均不应提交到仓库。

## 开发与文档

- [iOS App 架构、音频链路与真机验收记录](docs/ios-app-technical-design.md)
- [iOS 工程、模块部署与诊断](ios/DJOneHubUACProbe/README.md)
- [短信网关与只读范围](docs/qdc507-sms-gateway.md)
- [Bark / Web Push 模块提醒](docs/module-notifications.md)
- [模块长期授权与迁移](docs/module-authorization-lifecycle.md)
- [音频设备切换计划](docs/ios-call-audio-routing-plan.md)
- [连接提速计划](docs/ios-module-connection-speed-plan.md)
- [模块备份与恢复研究记录](docs/qdc507-backup-edl-sbl-recovery-report.md)

授权与提醒相关测试：

```sh
swift test --package-path ios/DJOneHubUACProbe
go test -race ./internal/modulepairing ./internal/modulepush ./cmd/djonehub-pairing-prepare ./cmd/djonehub-notify
```

其他控制协议、短信和音频离线测试见 iOS 工程说明。模块端 ARMv7 构建还需要匹配的工具链、运行库和产物校验；部分通话运行时不随仓库分发，详见[公开发布范围](OPEN_SOURCE_SCOPE.md)。

欢迎提交设备兼容性反馈、问题复现和改进建议。反馈时注明 iPhone 型号、iOS 版本、模块与固件信息，并隐藏电话号码、短信正文、验证码和所有密钥。

## 来源与许可

本项目基于原 VoHive 项目及模块研究工作继续开发，与 DJI、Quectel 或任何运营商不存在隶属或授权关系。感谢原作者 iniwex5、MaVo 及相关开源组件的贡献者。

仓库采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。使用和分发请遵循仓库许可证及各第三方组件声明。

```text
Required Notice: Copyright iniwex5 (https://github.com/iniwex5/vohive)
```

相关说明：[第三方声明](THIRD_PARTY_NOTICES.md) · [公开发布范围](OPEN_SOURCE_SCOPE.md)。
