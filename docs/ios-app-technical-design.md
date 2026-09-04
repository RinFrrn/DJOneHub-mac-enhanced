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
- 请求和响应使用完整 HMAC-SHA256，支持 `STATUS`、`DIAL`、`ANSWER`、`END`，以及
  固定范围的 `USB_AUDIO` 查询/切换。
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
| `mavo-pcm-bridge.armv7` | `052912efc5f9ef21ac891a5d2f9c457b3a3242f8423b17b3cb2f95418e982e48` |
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
| `dialing` | QMI state 01/04/05/0A | 250ms 轮询，开放下行；state 05 无带内音频时本地合成回铃，上行保持静音 |
| `incoming` | QMI state 02/07 | 显示接听和拒接 |
| `active` | QMI state 03 | 放行已经预热的双向 PCM；未预热时自动冷启动 |
| `ending` | 用户已请求挂断或 QMI state 08 | 禁止重复挂断，等待 STATUS 确认 |
| `recovering` | 控制或媒体暂时失败 | 保留明确故障原因并有限重试 |

媒体生命周期必须服从控制状态：

1. 主动拨号时立即预热；呼入只有用户点击“接听”后才访问麦克风和预热，单纯响铃不启动。
2. 预热阶段只发送每 250ms 一个认证静音包，使模块提前打开 PCM；不发送麦克风内容。
3. 主动拨号开始后立即开放下行，以播放带内忙音、彩铃和运营商提示；QMI state 05 且
   下行静音时按 ITU-T E.180 推荐范围本地合成 425Hz、1 秒响/4 秒停回铃，检测到真实
   带内音频后自动抑制本地音调。
4. 只有 control-session 凭据且 QMI 进入 conversation 状态后才放行麦克风上行。
5. 同一次建链最多发起一个麦克风权限/音频启动操作。
6. 通话结束、控制失败、配对撤销或用户退出时立即停止媒体。
7. UDP 三秒无合法包后模块自行关闭 PCM；iOS 同时主动释放本地 Audio Session。

## 6. 音频设计

### 6.1 第一阶段

- `AVAudioSession.Category.playAndRecord`，mode 为 `.voiceChat`。
- 首选内置麦克风，输出强制为 iPhone speaker。
- 麦克风输入通过 `AVAudioConverter` 转为 8 kHz / mono / S16_LE。
- 网络严格按 256 字节重分帧。
- 下行至少预缓冲四个 16 ms 帧后播放。
- 拨号/接听动作立即唤醒状态确认；建链期间 STATUS 使用 250ms 周期，active 后恢复 1 秒。
- 上下行门控分离：拨号阶段允许下行、禁止麦克风；接通后的额外播放缓冲仍只有四帧（约 64ms）。

### 6.2 第二阶段稳定性

- 下行 jitter buffer 使用有界序号窗口，拒绝重复包，按序消费乱序包。
- 丢包插入静音或轻量 PLC；不能直接拉长上一帧造成持续音调。
- 最多连续插入三个静音 PLC 帧；更长缺口在确认三个新包后直接快进，避免追赶已过时音频。
- 首次播放使用四帧预缓冲，欠载恢复使用独立的六帧门槛。
- 设置最大排队时长；超限丢弃最旧帧，避免延迟无限增长。
- 播放队列重置时推进 generation，忽略旧队列迟到的 completion，防止误扣新会话帧数。
- 处理 interruption、route change、media services reset、锁屏和前后台切换。
- 记录帧计数、丢包、乱序、重缓冲次数和峰值，但绝不记录 PCM 内容或 key。

模块 bridge 已在不改变网络协议的前提下完成 48 kHz/8 kHz 转换：上行采用跨帧连续
线性插值，下行采用 127-tap Q15 FIR 抗混叠后 6:1 抽取。iOS 仍只收发固定的 8 kHz、
单声道、S16_LE、256 字节媒体帧。

## 7. 网络恢复原则

- 控制操作在收到 challenge 后不自动重放，尤其不能自动重放 DIAL/ANSWER/END。
- 只有 TCP 建连阶段允许有限重试。
- STATUS 可以周期性重试，并用于所有写操作后的状态确认。
- UDP session ID 每次媒体启动随机生成且不能为零。
- USB 瞬断时停止发送；ECM 恢复后先 STATUS，再根据 conversation 状态决定是否重启媒体。
- UI 必须区分模块未连接、ECM 未就绪、认证失败、daemon 未监听和 PCM 失败。
- 正式 App 不用 `audio_enable` 控制系统声音路由。该节点只控制已枚举 UAC 的数据门，
  不会从 USB 描述符移除音频设备，也不会促使 iOS 改选扬声器。

## 8. 配对与安全

- pairing key 只存 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain 项。
- 禁止 iCloud 同步、日志输出、界面显示和诊断导出。
- 开发阶段继续支持经过校验的 JSON pairing bundle。
- 新导入的开发凭据已用 Keychain envelope v2 保存权限、创建时间和到期时间，并在每次
  恢复时复核；既有 v1 凭据首次恢复时自动补成从升级时起 30 天有效的 v2，不轮换当前
  key 或模块标识，也不要求重新导入。
- 本机撤销立即停止控制轮询和本地 PCM；模块侧开发 key 目前仍需接回 Mac 显式卸载。
- 正式配对仍需可信首次配对入口，并把 iPhone/模块双端撤销合成一个可报告部分失败的操作。
- 无凭据时不做裸 TCP 探测，防止消费旧 one-shot daemon。

## 9. 产品界面与本地数据

正式 App 使用用户熟悉的电话产品结构，而不是把协议和 PCM 探针直接暴露为首页：

- “最近通话”保存 DJOneHub 自己发起和收到的呼叫、结果与接通时长；它不是系统电话的
  全局通话记录。当前控制快照还没有来电号码，因此来电暂显示“未知号码”。
- “通讯录”只在用户点击授权后通过 `Contacts` 公共 API 本地读取；选择号码只填入拨号
  键盘，不上传联系人，也不直接绕过拨号确认。
- “拨号键盘”提供标准 12 键布局、紧凑模块状态和明确的拨号确认。
- “信息”保留为一级产品入口，但在 QDC507 增加受认证的 SMS 收取/发送协议前明确显示
  不可用；iOS App 不尝试读取系统短信数据库，也不展示虚假的发送按钮。
- 拨出、来电和通话使用全屏电话界面；通话中提供真实的上行静音与显式通话录音。
- 拨号页可持久开启自动录音；电话进入 active 且 PCM 可用后开始，用户在本次通话中手动
  停止后不会被状态刷新再次启动。
- 通话录音直接取现有 ECM PCM，保存为 8 kHz、16-bit、双声道 WAV（左声道本机、右声道
  对端），仅在用户确认后开始；每次录音使用独立文件名并关联到当前 DJOneHub 通话记录。
  文件使用设备文件保护、排除 iCloud 备份，可在通话记录或设置中播放、暂停和分享，也可在
  二次确认后永久删除。iPhone `.voiceChat` 采集在模块/网络 AGC 之前电平明显低于下行，
  因此只在写入 WAV 左声道时应用 24 倍饱和增益；发往模块的上行 PCM 保持原样。
- 模块配对、帧计数、丢包、乱序和重缓冲等信息移入“设置与诊断”。

UAC 路由、原始 endpoint、完整日志和测试音继续只保留在 Probe。

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

### M4：产品化电话界面

- 最近通话、通讯录、拨号键盘和信息四个主入口。
- 全屏来电/通话界面、静音和显式本地录音。
- 诊断信息从主流程下沉到设置。
- 扩展模块认证协议以提供来电号码和 SMS。

### M5：配对与 Beta

- 正式 bundle ID 与 Keychain 迁移。
- 无 Mac 首次配对方案。
- 隐私文案、图标、诊断导出、签名和 TestFlight。

CallKit/PushKit 仅在 M1–M3 稳定后单独立项。

## 11. 验收门槛

- 接通后无需按钮，PCM 在 1 秒目标窗口内自动启动。
- 上下行均清晰，不出现持续噪音、一次欠载后永久静音或延迟持续增加。
- 通话结束后麦克风、Audio Session、UDP 和播放器全部释放。
- 录音可同时辨认本机和对端声道；挂断后 WAV 可播放，时长与文件大小正确，并能从对应
  通话记录再次打开。
- 不再出现由测试逻辑造成的约 60 秒自动挂断。
- 模块以 Mac 端预先设置的 iPhone/iPad USB profile 启动，`USBCFG` 的 UAC 位为 0；
  iOS 不枚举模块音频设备，系统普通音频仍由 iPhone 扬声器播放。
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
- [x] Keychain v2 生命周期升级已无线安装验收：既有 `4a424aff…` v1 control-session
  凭据自动原地迁移，未轮换 key、未要求重新导入，App 启动后直接显示“可以拨号”。
- [x] 真机主动拨号、conversation 自动启动 PCM、双向清晰语音、超过 90 秒稳定通话、
  App 挂断及 PCM 自动停止验收通过。
- [x] 真机来电页面、接听、挂断和拒接验收通过。
- [x] 下行加入 3 帧乱序窗口、静音丢包补偿、序号跳变重置和播放断流自动恢复；
  离线测试、两个 iOS target 的 arm64 编译及真机长通话验收均已通过。
- [x] 移除正式 App 对 `UplinkPCMProbeModel` 的依赖，拆分为 `CallAudioCoordinator`、
  `PCMTransport`、`DownlinkPCMPlayer` 和 `DownlinkJitterBuffer`。
- [x] 实现 Audio Session interruption 和 media-services reset 的受控重建；仅当模块 STATUS
  仍确认存在 active call 时恢复新 PCM session，等待真机中断场景验收。
- [x] route change 暂时维持已验证的“音频启动时固定内置麦克风和扬声器”；运行中主动
  重设曾触发听筒/扬声器反复切换的通知反馈循环；撤回后真机双向通话恢复正常，后续采用
  去抖状态机并在隔离测试中单独实现。现已加入 500ms 安静窗口：正确路由和空闲通知不做
  任何操作；运行中的错误路由先停止 PCM，稳定后只请求一次恢复，并继续要求新 STATUS
  确认通话仍存在。针对 iOS 27 蓝牙切换可能只发 interruption began 或
  `routeDisconnected`、不补 ended 的路径，增加延迟路由重激活探测；探测失败时保持暂停，
  不循环抢占系统音频。修复版已完成真机蓝牙连接/断开验收：通话继续使用 iPhone 内置
  麦克风和扬声器，双向音频不受影响，未再出现系统音频永久暂停或听筒/扬声器切换循环。
- [x] 增加丢包补偿、乱序、重复/迟到拒绝、序号重置、重缓冲和队列丢弃指标；
  指标不包含 PCM 内容或配对密钥。加入 generation 隔离、六帧重缓冲和长缺口快进后的
  签名版本已无线安装；真机通话结果为丢包 0、乱序 0、队列丢弃 0、无感重缓冲 1，验收通过。
- [x] 为稳定性验收补充通话计时、本次 App 运行的媒体恢复次数，以及此前未在正式页面展示的
  序号丢弃/重置计数；所有观测仅记录计数，不记录 PCM 内容或配对密钥。真机 3 分钟快速回归
  已通过，双向音频和锁屏恢复正常，丢包、乱序、队列丢弃、序号丢弃/重置等观测均为 0；
  30 分钟正式压力测试延后至 TestFlight 前集中执行一次。
- [x] 将 macOS 已验证的低延迟策略迁移到 ECM PCM：拨号/接听即预热 AudioSession、
  AVAudioEngine 和模块 PCM，预热阶段仅发认证静音；拨号阶段放行下行，QMI active 后
  才放行麦克风；无带内回铃时由 App 本地合成并为真实网络音频让路；
  建链 STATUS 提升到 250ms，并保留 64ms 下行预缓冲；真机来电接听首音延迟已确认基本
  可以接受，主动拨号及挂断后连续重拨也已通过，旧 UDP session 未影响下一通电话。
- [ ] 完成 ECM 拔插、锁屏及前后台切换验收。
- [ ] 正式 App 已声明 `audio` 后台模式，并在 PCM 失败及重新进入前台时解除旧启动锁、
  重新确认 STATUS 后恢复活动通话媒体；首次后台基线测试确认旧版会断音且无法自恢复，
  新签名版本已通过通话中切至其他 App、后台持续双向音频、返回前台以及锁屏/解锁期间
  持续双向音频验收。当前模块没有独立供电，拔除 iPhone 数据线会同时重启模块；持久
  开发 marker/key 会在再次供电时恢复 daemon，但这不是同一 TCP/UDP 会话的 ECM 瞬断，
  因此真实链路瞬断恢复仍需在具备独立供电/数据断开条件后验收。
- [x] 修正锁屏期间对端挂断后的状态文案：周期 STATUS 原本只替换 `calls` 快照、不替换
  上一次 DIAL/ANSWER 的详情，造成电话按钮已回到空闲但连接区仍显示旧“拨号中”；现在
  静默轮询成功时同步刷新为最新通话摘要或“当前无活动通话”。
- [x] 控制重连不再让陈旧 call snapshot 压过连接失败：STATUS 失败完成前保留既有媒体，
  一旦确认失败则进入“正在恢复连接”并停止使用旧拨号/通话状态；重新认证 STATUS 成功后
  才按模块真实 snapshot 恢复媒体。新签名版本已完成真机拔插验收：拔除模块约 20 秒时
  先显示“正在连接模块”，请求确认失败后显示“正在恢复连接”；重新插入并启动模块后无需
  重新导入，自动回到“可以拨号”。
- [x] 缩短稳态断线识别：每秒周期 STATUS 的 TCP 建连预算从通用 20 秒拆为 3 秒，失败后
  进入恢复态；首次启动和恢复 STATUS 仍使用 20 秒预算等待模块冷启动。等待真机拔插确认
  “正在恢复连接”的出现时间明显短于旧版约 20 秒。新签名版本已完成真机拔插验收，
  快速断线识别与重新上电后的自动“可以拨号”流程均正常。
- [x] 收口通话中断线媒体状态：控制断线后明确停止本地 PCM；PCM/AudioSession 恢复必须
  等待一个更新的认证 STATUS 成功代次并确认通话仍存在，不能依据旧 snapshot 立即重启；
  所有 UDP/player 回调按媒体 generation 隔离，旧 session 的迟到失败不得停止新 session。
  已完成真机验收：通话中拔出模块后 PCM 明确停止且帧计数停止；模块重新上电后自动回到
  “可以拨号”，不会从旧通话 snapshot 恢复媒体；再次拨号双向音频正常，旧 UDP 回调未干扰
  新媒体 session。
