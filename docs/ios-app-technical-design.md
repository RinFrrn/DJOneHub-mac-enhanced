# DJOneHub iOS App 技术设计与实施计划

## 1. 目标

构建独立于 Mac 的 DJOneHub iOS App，通过 USB ECM 直接控制 QDC507 电话并承载双向
PCM。正式通话媒体不经过 USB UAC；iPhone/iPad 模式下模块关闭 UAC gadget，避免系统
音频被模块枚举成的 USB 声卡抢占。

第一阶段的产品目标是前台通话 MVP：用户完成一次配对后，可以在 App 内拨号、接听、
挂断；进入 conversation 状态后自动启动双向 PCM，通话结束后自动释放麦克风、扬声器和
网络资源。用户不再需要手动执行 STATUS、测试音或“开始 PCM”。

当前阶段明确不接入 CallKit、PushKit，也不承诺 App 被杀死后的系统级来电唤醒。

## 2. 已验证基线

### 2.1 控制面

- 模块地址：`192.168.225.1:45750/TCP`。
- 每个请求使用新 TCP 连接；服务端先发 32 字节 challenge。
- 请求和响应使用完整 HMAC-SHA256，支持 `STATUS`、`DIAL`、`ANSWER`、`END`。
- iOS 使用 `Network.framework`，强制 `.wiredEthernet`，不会误走蜂窝或 Wi-Fi。
- 32 字节 pairing key 已使用不可同步 Keychain 保存。
- 当前稳定模块标识为 pairing key 的 SHA-256 前 16 字节十六进制值。

### 2.2 媒体面

- 模块地址：`192.168.225.1:45751/UDP`。
- 网络 PCM 固定为 8000 Hz、单声道、signed S16 little-endian。
- 每包 128 samples / 256 bytes / 16 ms，包头携带 session、sequence 和 sample clock。
- 包使用截断为 16 字节的 HMAC-SHA256 tag。
- 上行：iPhone 内置麦克风 → ECM → Media1 playback → `VOICE_PLAYBACK_TX` → voice DSP。
- 下行：voice DSP → `INCALL_RECORD_RX` → Media1 capture → ECM → iPhone 扬声器。
- QDC507 定制声卡、PCM bridge、冷启动自动恢复和 UAC-disabled 移动模式均已真机通过。

### 2.3 固定模块产物

| 产物 | SHA-256 |
|---|---|
| `mavo-pcm-bridge.armv7` | `e8b8b9b227b1c716e7889930c61686cc68cf2f69c8699772d3f5eaeff2887b51` |
| `qdc507_incall_card.new.ko` | `dfabcecff905b97ed46f755f4667e7c2635799e00524a10a8ed9d546bd1feea7` |

## 3. 工程策略

保留 `DJOneHubUACProbe` target 作为实验和硬件诊断工具。在同一 Xcode 工程新增正式
`DJOneHub` target：

- 两个 target 共享已经过测试的控制协议、媒体协议、Keychain 和网络客户端源码。
- 正式 target 不编译 UAC 路由探针、实验按钮和诊断首页。
- 正式 target 使用独立 App 入口、产品首页和通话生命周期协调器。
- 开发期 `DJOneHub` 暂时沿用 `io.github.rogerbush007.DJOneHubUACProbe` bundle ID，
  以继承真机上现有默认 Keychain access group；这意味着两个 target 不能同时安装。
- TestFlight 前建立共享 Keychain access group 或一次性凭据迁移，再切换正式 bundle ID。

不在第一阶段引入第三方依赖。音频、网络、安全存储和 UI 均使用 Apple 公共框架。

## 4. 运行时架构

```text
DJOneHubApp
  └─ CallLifecycleCoordinator
      ├─ VoiceControlModel / VoiceControlClient (TCP 45750)
      ├─ CallAudioCoordinator
      │   ├─ AVAudioSession + AVAudioEngine
      │   ├─ PCMTransport (UDP 45751)
      │   ├─ DownlinkPCMPlayer
      │   └─ DownlinkJitterBuffer
      └─ DJOneHubRootView
```

第一阶段复用的 `UplinkPCMProbeModel` 已在第二阶段拆除；Probe 与正式 App 目前共享以下正式
媒体组件，但只有 Probe 暴露测试音等诊断入口：

- `CallAudioCoordinator`
- `PCMTransport`
- `DownlinkJitterBuffer`
- `DownlinkPCMPlayer`

协议、PCM 格式和硬件路由均未随此次拆分改变。

## 5. 产品通话状态机

| 产品状态 | 来源 | 行为 |
|---|---|---|
| `needsPairing` | Keychain 无控制凭据 | 只允许导入/添加模块 |
| `connecting` | 首次 STATUS 或 ECM 恢复中 | 有界重试，不允许重复控制操作 |
| `ready` | STATUS 成功且无通话 | 允许拨号 |
| `dialing` | QMI state 01/04/05 | 250ms 轮询，预热本地音频与模块 PCM，媒体保持静音 |
| `incoming` | QMI state 02/07 | 显示接听和拒接 |
| `active` | QMI state 03 | 放行已经预热的双向 PCM；未预热时自动冷启动 |
| `ending` | 用户已请求挂断 | 禁止重复挂断，等待 STATUS 确认 |
| `recovering` | 控制或媒体暂时失败 | 保留明确故障原因并有限重试 |

媒体生命周期必须服从控制状态：

1. 主动拨号时立即预热；呼入只有用户点击“接听”后才访问麦克风和预热，单纯响铃不启动。
2. 预热阶段只发送每 250ms 一个认证静音包，使模块提前打开 PCM；不发送麦克风内容，也不播放下行。
3. 只有 control-session 凭据且 QMI 进入 conversation 状态后才放行真实双向媒体。
4. 同一次建链最多发起一个麦克风权限/音频启动操作。
5. 通话结束、控制失败、配对撤销或用户退出时立即停止媒体。
6. UDP 三秒无合法包后模块自行关闭 PCM；iOS 同时主动释放本地 Audio Session。

## 6. 音频设计

### 6.1 第一阶段

- `AVAudioSession.Category.playAndRecord`，mode 为 `.voiceChat`。
- 首选内置麦克风，输出强制为 iPhone speaker。
- 麦克风输入通过 `AVAudioConverter` 转为 8 kHz / mono / S16_LE。
- 网络严格按 256 字节重分帧。
- 下行至少预缓冲四个 16 ms 帧后播放。
- 拨号/接听动作立即唤醒状态确认；建链期间 STATUS 使用 250ms 周期，active 后恢复 1 秒。
- 预热与媒体放行分离，接通后的额外播放缓冲仍只有四帧（约 64ms）。

### 6.2 第二阶段稳定性

- 下行 jitter buffer 使用有界序号窗口，拒绝重复包，按序消费乱序包。
- 丢包插入静音或轻量 PLC；不能直接拉长上一帧造成持续音调。
- 首次播放和欠载恢复采用独立预缓冲门槛。
- 设置最大排队时长；超限丢弃最旧帧，避免延迟无限增长。
- 处理 interruption、route change、media services reset、锁屏和前后台切换。
- 记录帧计数、丢包、乱序、重缓冲次数和峰值，但绝不记录 PCM 内容或 key。

模块内部 48 kHz/8 kHz 的带滤波重采样属于模块 bridge 产品化工作，不由 iOS 改变网络
协议来规避。

## 7. 网络恢复原则

- 控制操作在收到 challenge 后不自动重放，尤其不能自动重放 DIAL/ANSWER/END。
- 只有 TCP 建连阶段允许有限重试。
- STATUS 可以周期性重试，并用于所有写操作后的状态确认。
- UDP session ID 每次媒体启动随机生成且不能为零。
- USB 瞬断时停止发送；ECM 恢复后先 STATUS，再根据 conversation 状态决定是否重启媒体。
- UI 必须区分模块未连接、ECM 未就绪、认证失败、daemon 未监听和 PCM 失败。

## 8. 配对与安全

- pairing key 只存 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain 项。
- 禁止 iCloud 同步、日志输出、界面显示和诊断导出。
- 开发阶段继续支持经过校验的 JSON pairing bundle。
- 正式配对需要保存凭据版本、模块标识、权限和生命周期元数据。
- 撤销配对必须同时停止控制轮询和本地 PCM。
- 无凭据时不做裸 TCP 探测，防止消费旧 one-shot daemon。

## 9. UI 范围

前台 MVP 包含：

- 模块连接/认证状态。
- 拨号输入、拨号确认。
- 来电接听与拒接。
- 通话中挂断。
- 自动媒体状态、上下行电平和帧数的简化指示。
- 添加/替换/撤销模块配对。

UAC 路由、原始 endpoint、PCM 格式、完整日志和测试音只保留在 Probe 或后续隐藏诊断页。

## 10. 实施里程碑

### M1：前台自动通话 MVP

- 新增正式 target 和产品首页。
- 自动恢复 Keychain 配对。
- 自动 STATUS 轮询。
- QMI 状态驱动拨号、接听、挂断 UI。
- conversation 自动启动 PCM，通话结束自动停止。
- 真机完成一次主动和一次被动双向通话。

### M2：媒体稳定性

- 拆分探针媒体模型。
- 实现 jitter buffer、欠载重缓冲、丢包策略和指标。
- 完成 5/30/60 分钟通话与双方同时说话测试。

### M3：连接与生命周期

- ECM 拔插恢复。
- Audio Session interruption / route / reset 恢复。
- 已建立通话的锁屏与后台保持验证。

### M4：配对与 Beta

- 正式 bundle ID 与 Keychain 迁移。
- 无 Mac 首次配对方案。
- 隐私文案、图标、诊断导出、签名和 TestFlight。

CallKit/PushKit 仅在 M1–M3 稳定后单独立项。

## 11. 验收门槛

- 接通后无需按钮，PCM 在 1 秒目标窗口内自动启动。
- 上下行均清晰，不出现持续噪音、一次欠载后永久静音或延迟持续增加。
- 通话结束后麦克风、Audio Session、UDP 和播放器全部释放。
- 不再出现由测试逻辑造成的约 60 秒自动挂断。
- UAC 关闭时系统普通音频仍由 iPhone 扬声器播放。
- 30 分钟通话无崩溃；60 分钟压力测试无资源持续增长。
- 错误 key、篡改包、错误 session 和非 wiredEthernet 路径全部 fail closed。

## 12. 当前实施切片

本轮首先交付 M1 的工程骨架和自动生命周期：

1. 新增 `DJOneHub` target。
2. 新增正式 App 入口与主页面。
3. 新增 `CallLifecycleCoordinator`。
4. Keychain 恢复后自动 STATUS；conversation 自动启停现有真机验证 PCM 引擎。
5. 使用 iphoneos SDK 无签名编译验证两个 target。

### 2026-09-03 实施状态

- [x] 新增独立 `DJOneHub` target，原 Probe target 保留。
- [x] 新增正式 App 入口、前台电话首页和配对管理入口。
- [x] 新增可离线测试的产品通话状态机。
- [x] Keychain 恢复后自动 STATUS，轮询期间 UI 不退回连接态。
- [x] conversation 自动启动 ECM 双向 PCM，通话结束自动停止。
- [x] 控制操作区分拨号、接听和挂断中的瞬时状态，避免重复提交。
- [x] 正式 App 与 Probe 均通过 iphoneos arm64 无签名构建。
- [x] 状态机、控制协议、媒体协议和 pairing bundle 离线测试通过。
- [x] 正式 App 通过 Apple Development 签名并安装到真机。
- [x] 真机首屏自动恢复既有 Keychain 配对，并自动进入“可以拨号”。
- [x] 真机主动拨号、conversation 自动启动 PCM、双向清晰语音、超过 90 秒稳定通话、
  App 挂断及 PCM 自动停止验收通过。
- [x] 真机来电页面、接听、挂断和拒接验收通过。
- [x] 下行加入 3 帧乱序窗口、静音丢包补偿、序号跳变重置和播放断流自动恢复；
  离线测试、两个 iOS target 的 arm64 编译及真机长通话验收均已通过。
- [x] 移除正式 App 对 `UplinkPCMProbeModel` 的依赖，拆分为 `CallAudioCoordinator`、
  `PCMTransport`、`DownlinkPCMPlayer` 和 `DownlinkJitterBuffer`。
- [x] 实现 Audio Session interruption 和 media-services reset 的受控重建；仅当模块 STATUS
  仍确认存在 active call 时恢复新 PCM session，等待真机中断场景验收。
- [ ] route change 暂时维持已验证的“音频启动时固定内置麦克风和扬声器”；运行中主动
  重设曾触发听筒/扬声器反复切换的通知反馈循环；撤回后真机双向通话恢复正常，后续采用
  去抖状态机并在隔离测试中单独实现。
- [x] 增加丢包补偿、乱序、重复/迟到拒绝、序号重置、重缓冲和队列丢弃指标；
  指标不包含 PCM 内容或配对密钥，签名版本已安装，等待真机通话数值验收。
- [x] 将 macOS 已验证的低延迟策略迁移到 ECM PCM：拨号/接听即预热 AudioSession、
  AVAudioEngine 和模块 PCM，预热阶段仅发认证静音；QMI active 后才放行麦克风与下行；
  建链 STATUS 提升到 250ms，并保留 64ms 下行预缓冲，等待真机首音延迟验收。
- [ ] 完成 ECM 拔插、锁屏及前后台切换验收。
