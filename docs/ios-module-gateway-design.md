# DJOneHub iOS 模块侧电话网关设计

## 1. 目标与结论

目标是在不依赖 Mac 或另一台常驻设备的情况下，让 iPhone 通过 USB 直连大疆第一代 4G 模块，在前台完成拨号、接听、挂断和双向通话。

当前 macOS 实现不能原样移植到 iOS：它依赖 libusb/IOKit 直接访问模块的 USB AT、ADB 和 UAC 接口，而普通 iOS App 没有这些能力。可行方向是把电话控制和语音传输移到模块内部，再通过 iPhone 能识别的 USB 网络功能向 App 提供受控协议。实机基线是 Qualcomm 厂商 `rmnet`，不是通用 USB Ethernet。ECM 已分别在 Mac 和真实 iPhone 上完成枚举、上网及模块 TCP 闭环验证；NCM 仍未验证。

### 1.0 控制平面当前进度（2026-08-30）

QDC507 当前 ECM 地址固定为 `192.168.225.1`，认证 voice daemon 监听 TCP `45750`。
现有一次性候选已在 Mac 侧完成真实来电 `STATUS`、`ANSWER`、`END` 验收；最近一次
`STATUS` 部署结果明确为 `authenticated=true`、`one_shot=true`、`persistent=false`。
这只证明控制面，不代表 iOS 双向通话媒体已经完成。

`ios/DJOneHubUACProbe` 现在增加纯 Swift 控制客户端：

- `Network.framework` 建立 ECM TCP 连接，每连接只允许一个请求，并强制走
  `.wiredEthernet`，避免相同 Wi-Fi 子网抢占路由；
- `CryptoKit` 执行完整 32-byte HMAC-SHA256(`nonce || unsigned frame`)；
- 严格解析 20-byte 大端 header、32-byte HELLO nonce、request ID、状态码和 call snapshot；
- 仅暴露 `status/dial/answer/end` async API，不提供任意 QMI/AT 透传；
- pairing key 必须由调用方注入 32 字节内存值，仓库不硬编码、不生成凭据；生产配对
  完成后只允许按稳定模块标识显式写入不可同步的设备 Keychain；
- connect/read/write 默认 5 秒有界，超时和任务取消都会关闭连接；
- DIAL 与 call ID 在客户端先做白名单校验。

探针 UI 已接入受限电话控制区域：`VoiceControlModel` 默认没有凭据；短期 STATUS 凭据
只能读取状态，短期 control-session 凭据才会显示拨号、按 call ID 接听和挂断。App
每秒执行一次认证 STATUS 轮询来刷新来电状态，拨号前要求界面二次确认。UI 不接收自由
格式 AT/QMI 命令，也不把 key 放入文本框、UserDefaults 或日志。

仍未完成：模块到 iPhone 的双向 PCM 媒体传输、生产 pairing/轮换/撤销、后台来电与
CallKit 生命周期、以及真机上完整的 iOS 本地网络/USB 配件权限和断线恢复策略。

为推进只读 STATUS 实机闭环，仓库增加了明确标注为 development-only 的一次性测试配对：
Mac 后端生成随机 32 字节 key、在模块启动一次认证 daemon，并输出一小时内可导入的 JSON
配对包；iOS 校验固定 purpose/endpoint、有效期和 key 指纹后，按模块写入不可同步
Keychain。该流程仍依赖 Mac 完成首次武装，不能替代下节要求的生产信任根。

STATUS 实机闭环通过后又增加了 `development-control-session`：模块下次启动时只消费一次
marker，daemon 就绪后删除模块磁盘上的 key，但不以 `--once` 退出，因此同一供电周期可
连续执行 `STATUS / DIAL / ANSWER / END`。断电即结束会话。原
`development-status-only` 明确以 `--once --status-only` 启动，非 STATUS 请求在模块
侧返回 `FORBIDDEN`，iOS Keychain 的旧 32 字节裸值也只会迁移为只读权限。

### 1.0.1 配对是独立的产品门槛

当前 daemon 的 `--key-file` 只解决“双方已经持有同一把密钥”后的认证，并没有解决
首次把密钥安全交给 iPhone。ECM 是可访问网络，不能把 pairing key 明文或通过未认证
TCP 传给 App；否则插入模块的任意主机都能接管电话控制。要实现真正的“只用 iPhone”，
模块还必须提供一个用户可确认的一次性配对通道，例如实体按键/LED PIN、出厂 QR 或
受保护的 USB 配置接口。配对完成后再执行以下生命周期：

1. iPhone 生成临时公钥并发送配对请求；模块仅在物理确认窗口内接受请求。
2. 双方用临时密钥协商出会话密钥，模块随机生成新的 32 字节控制 key，并只通过该
   加密会话返回一次。
3. iPhone 将 key 放入 Keychain（不可同步、设备解锁后可用），模块以 `0600` 写入
   `/usrdata/djonehub/pairing.key`；两端回读指纹，不回显 key 内容。
4. 轮换先建立第二把 key 并完成一次 STATUS，再原子替换旧 key；撤销则清除模块 key
   并让 App 删除对应 Keychain 项。

在上述硬件/固件配对入口落地前，App 只能保留内存注入和只读 STATUS 的开发接口，不能
声称已具备无 Mac 的生产拨号能力。

### 1.1 现有 UAC 不能单独组成 iPhone 通话

2026-08-28 使用本机 Xcode 27 / iOS 27 SDK 复核 Apple 公共 API 后，否定了“保留
模块 UAC 作为全部通话媒体、USB 网络只做控制”的中间方案：

- 模块电话下行在 iPhone 上表现为 USB Audio **输入**，而说话人的声音来自 iPhone
  内置麦克风；完整通话要求同时采集两个输入设备。
- 模块电话上行在 iPhone 上表现为 USB Audio **输出**，而用户需要从 iPhone 听筒或
  扬声器听到下行；完整通话也要求同时使用两个输出设备。
- 普通 `playAndRecord` 可以从 `availableInputs` 选择一个偏好输入，但这不是并行采集。
- 传统 `multiRoute` 明确将输入限制为 last-in input；内置扬声器也只允许在没有其他
  eligible output 时使用。
- iOS 26.2 的 `dualRoute` 虽能同时使用内置麦克风/扬声器与第二套双向设备，但 Apple
  当前只列出有线耳麦、Bluetooth LE 和 Bluetooth HFP，明确没有 USB Audio。

因此现有 UAC 只保留为 macOS 媒体路径和 iPhone 实机诊断手段，不能作为 iOS 生产架构
的完成条件。生产方案仍需把电话上下行都暴露给模块用户态网关，经 ECM/NCM 传给 App；
iPhone 的 Audio Session 只使用一套正常的内置/耳麦通话路由。

### 1.2 iPhone 27 真机拆向验证

在 iPhone 18,4、iOS 27.0 和 QDC507 `BAIWANG` UAC 实机上，探针得到以下结果：

- 模块空闲时可枚举为 `AC Interface` 输入和 `AS Interface` 输出，均为单声道
  USB Audio，8 kHz、23 ms buffer。
- 选择内置麦克风后，路由为“内置麦克风输入 + 模块 USB 输出”，采样率 48 kHz；
  `AVAudioEngine` 可稳定把麦克风 PCM 渲染到 USB 输出，输入电平随说话变化。
- 选择“USB 输入 + iPhone 扬声器”时，iOS 的 `overrideOutputAudioPort(.speaker)` 会
  同时把输入强制切回内置麦克风。模块 USB 输入仍列在 `availableInputs`，但为 0 ch，
  不能被当前音频图读取。
- 首次在路由切换后立即建图曾触发 `com.apple.coreaudio.avfaudio -10868` 并导致 App
  退出；等待最后一个 route-change 事件稳定 500 ms 并重建 `AVAudioEngine` 后可避免。

这组实测把“两个方向分别可用”和“同一会话全双工可用”明确区分开：前者成立，后者
仍被 iOS 单一当前输入与扬声器路由规则阻断。探针中的扬声器模式只用于记录该限制，
不是生产通话实现。

仓库已增加 `ios/DJOneHubUACProbe`，可把两个方向拆开验证：选择 USB 输入观察电话下行，
或选择内置麦克风并在 USB 输出仍存在时短暂验证上行。即使两项分别成功，也不等于它们
能在同一个 iOS Audio Session 中同时工作。

推荐架构：

```text
模块内部
├── djonehubd                    常驻控制 daemon
│   ├── 独占并串行化 AT/QMI 控制通道
│   ├── 解析 RING、CLIP、CLCC 等状态
│   ├── 提供经过鉴权的 TCP 控制协议
│   └── 按每通电话启动/停止音频 helper
│
└── mavo-pcm-gateway             每通电话运行（需内核暴露正确双向 PCM）
    ├── 配置并回滚 VoLTE mixer
    ├── 打开模块 PCM 设备
    ├── UDP 接收 iPhone 上行 PCM
    └── UDP 发送运营商下行 PCM

USB 网络（待验证 ECM/NCM；当前 rmnet 不可直接使用）
└── iPhone App
    ├── Network.framework 控制和音频
    ├── AVAudioEngine/VoiceProcessingIO
    ├── CallKit 通话界面
    └── Contacts/SwiftUI
```

这里的媒体 PCM 不能继续使用已被实机否定的 D5 playback / D6 capture 映射，也不能用
当前无法 prepare 的 D0/MultiMedia1 路径。下一实现门槛是修改/扩展 QDC507 内核音频
驱动，向用户态提供 `PCM_RX` 蜂窝下行 capture 和 `PCM_TX` 蜂窝上行 playback，并与
现有 `f_audio` UAC 会话互斥。

控制 daemon 可以常驻，但音频 helper 必须维持“每通电话一个 session”的生命周期。不要让当前 `--voice-route-session` 永久运行，否则容易重新引入第二通电话无声、旧 PCM 句柄未清理和 mixer 状态残留。

## 2. 当前模块侧实现

参考源码固定为 MaVo 提交：

- Commit：`0443dfdaf8aec086fd76ba2ee9152fd908114524`
- Helper 源码：`module/mavo_pcm_bridge.c`
- ARMv7 构建脚本：`scripts/build_pcm_bridge_armel.sh`

当前 helper 有两条路径：

1. 默认模式把 `/dev/ttyGS0` 与 `hw:0,0` 双向搬运，格式为 8 kHz、单声道、PCM S16LE。
2. `--voice-route-session` 配置 VoLTE mixer、打开 `hw:0,4` hostless PCM、启用 `/sys/class/android_usb/f_audio/audio_enable`，收到 `SIGTERM` 后逆序回滚。

当前 DJOneHub 会通过 USB ADB：

1. 检查 root 与内核版本。
2. 临时推送 `qdc507_aprv3.ko`、`qdc507_voice.ko` 和 helper。
3. 校准 VoLTE ACDB。
4. 启动 `--voice-route-session`。
5. 挂断后停止 helper，并执行 USB Audio 与 voice route 回滚。

注意：macOS 端使用项目内的 libusb ADB 客户端直接 claim 厂商接口（当前设备在
macOS IORegistry 中显示为 `ADB Interface@5`、`bInterfaceSubClass=66`），不是系统
`adb` 守护进程。因而即使模块已被 macOS 枚举，命令行 `adb devices` 也可能为空；
判断模块是否可用应以 IORegistry 和 DJOneHub 自带的 USB ADB 客户端为准。

iPhone 无法执行这条 ADB 控制链，因此驱动准备、电话控制和音频 session 管理最终都必须由模块上的常驻 daemon 接管。

### 2.1 USB 网络实机盘点

本次从模块运行态读取到：

```text
/sys/class/android_usb/android0/functions = diag,serial,rmnet,ffs,audio
bridge0 = 192.168.225.1/24
bridge0/brif = 空
```

模块内核同时暴露 `f_ecm`、`f_ncm`、`f_rndis` 和 `f_usb_mbim` 等 function 节点，
但“节点存在”不等于该组合已经配置、能枚举或被 iPhone 支持。当前 macOS 未出现对应
`en*` 接口，说明 `rmnet` 不能作为本方案假定的通用 IP 链路；普通 iOS App 也不能直接
claim 这个厂商 USB function。

因此后续必须在不持久化的试验模式中分别验证 ECM/NCM：保存当前完整 USB tuple，设置
自动回滚窗口，确认 Mac 和真实 iPhone 的枚举、DHCP/静态地址、ADB/AT 救援入口及冷启动
恢复。未通过这项测试前，不得把“USB Ethernet 可用”作为既成事实，也不得永久改写
`USBCFG`。

### 2.2 ECM 临时实测（2026-08-28）

在未修改 `USBCFG`、MTD 或启动脚本的前提下，通过 `AT+QCFG="usbnet",1` 并重启模块，
Mac 成功枚举出 ECM：

```text
接口：en10
IPv4：192.168.225.28/24
模块网关：192.168.225.1（模块 bridge0）
USB 控制接口：bInterfaceClass=2, bInterfaceSubClass=6
USB 数据接口：bInterfaceClass=10
驱动：AppleUserECM / AppleUserECMData
```

同一枚举中仍保留 USB AT（接口 2）、ADB（接口 6）和 UAC（接口 7–9），说明 QDC507
当前组合可以在保留救援/音频接口的同时提供 ECM。该次切换的恢复目标仍是原始
`usbnet=0`。后续真实 iPhone 已能通过该 ECM 有线网络上网，并能连接模块
`192.168.225.1:45750` 的一次性 sentinel；NCM 尚未通过实机测试。

## 3. 进程职责

### 3.1 `djonehubd`

`djonehubd` 负责非实时工作：

- 找到并独占一个确认安全的模块内部 AT/QMI 通道。
- 串行化全部 AT 请求，避免命令响应和 URC 混流。
- 只向网络客户端开放拨号、接听、挂断、DTMF 和状态查询等白名单操作。
- 在 dialing、alerting、incoming、waiting 阶段预热模块语音路由。
- 在 active 后开放媒体传输。
- 挂断后延迟约 1.5 秒停止音频 session，确保 iPhone 侧先关闭音频。
- 驱动或音频失败时执行有界回滚，不自动重启或刷写模块。

建议状态检测策略与 DJOneHub 1.2.11 一致：

- 拨号、接听、挂断命令成功后立即唤醒状态检测。
- 建链状态 `CLCC` 间隔 250 ms。
- active 与 idle 状态间隔 1 s。
- 能可靠接收 URC 时优先用事件，轮询作为校验和恢复手段。

#### 3.1.1 QMI Voice 控制基线

真实 QDC507 已验证模块自带 `libqmiservices.so` / `libqmi_cci.so` 可提供 QMI Voice
service object `2/0x4d/6`。固定哈希 ARMv7 soft-float 探针成功初始化 QMI client，
只读执行 Get All Call Info (`0x2f`) 并释放 client，因此控制面不再依赖未确认用途的
内部 TTY。

仓库中的 `djonehub_voice_codec` 依据 libqmi Voice wire definition 固化以下最小集合：

- Dial Call `0x20`：号码使用 mandatory TLV `0x01`；
- End Call `0x21`、Answer Call `0x22`：call ID 使用 mandatory TLV `0x01`；
- Get All Call Info `0x2f`：call information 使用 TLV `0x10`，每条记录 7 字节；
- 通用 QMI result 使用 TLV `0x02`，action response 的 call ID 使用 TLV `0x10`。

必须注意：旧只读探针曾错误查找 call information TLV `0x01`。空闲响应没有 call
information 时仍会得到“零通话”，所以这类成功只证明 QMI transport 可用，不能证明
活动通话解析正确。修正版需先用真实来电完成只读验收，再按 STATUS、DIAL、ANSWER、
END 的顺序逐项开放写操作。所有写操作必须串行、限定超时、回读 `0x2f` 确认最终状态，
且不得提供任意 QMI message 透传。

真实响铃只读验收现已完成：Get All Call Info 返回 `id=1`、`state=incoming`、
`direction=MT`，说明修正后的活动 call record 解析有效。仓库已加入不由 macOS API 部署
的 one-shot control 候选及独立策略单测，下一步先在模块上只运行其 `status` 子命令，
核对它与只读探针完全一致，再逐项人工确认开放写命令。

候选 `status` 已在真实模块返回 `exit_status=0` 和空闲快照，与独立只读探针一致。后续
写接口使用固定 route 映射到固定子命令，不接受任意 operation；每次请求还必须携带
精确操作确认串。号码只允许数字、开头的 `+`、`*`、`#`，Call ID 只允许 1..255，
二者在 macOS 后端和 ARM 候选内重复校验，避免 shell/QMI 参数透传。

真实来电的 Answer/End 闭环也已完成。部署端先读取唯一 `incoming` call ID，固定
`answer` 操作在约 0.43 秒内回读到成功，独立状态查询确认 `conversation`；随后固定
`end` 操作在约 0.43 秒内确认，最终快照为空。由此 STATUS、ANSWER、END 的 QMI
transport、消息格式、状态策略和清理路径均已通过实机验证；DIAL 仍需使用明确的测试
号码单独验收。通话期间 macOS 的旧 MaVo 音频桥启动失败不属于 QMI 控制故障，媒体面
仍需按本设计由模块网关和 iOS 客户端另行实现。

#### 3.1.2 ECM 闭环 sentinel

在真正接入内部 AT 通道前，可以先部署仓库中的 `module/djonehubd.c` 做网络闭环
验证。该程序只绑定 `192.168.225.1:45750`、接受 TCP 连接并返回固定健康响应，不
执行 AT、拨号、PCM、shell 或持久化配置。它的目的仅是把 iOS 探针从 `ECONNREFUSED`
推进到“控制端口可达”，证明 ECM 地址、路由和模块侧监听路径正确。

模块上的 `POSIX error 61` 等价于 `ECONNREFUSED`，表示链路已到达目标地址但没有
监听进程；这不是 iOS 本地网络权限失败。sentinel 必须使用 QDC507 匹配的 glibc
sysroot 构建并以前台临时方式运行，验证完成后退出。生产版 `djonehubd` 仍需另行
实现配对认证、AT 通道串行化和有界状态机，不能直接把 sentinel 注册进持久启动脚本。

### 3.2 `mavo-pcm-gateway`

`mavo-pcm-gateway` 只负责实时媒体和严格回滚：

- 不解析电话 JSON。
- 不直接执行任意 shell。
- 不管理短信或 eSIM。
- 不在实时 PCM 循环中写日志、文件或获取锁。
- 控制面失联或媒体心跳超时后主动退出。
- 每次退出都逆序关闭 PCM、关闭 mixer，并恢复旧 route。

## 4. Helper 源码修改

### 4.1 重构 voice route 生命周期

把当前 `run_voice_route_session()` 拆为可复用的开始与停止：

```c
struct voice_route_state {
    void *route_playback;
    void *route_capture;
    int legacy_downlink_disabled;
    int legacy_uplink_disabled;
    int downlink_enabled;
    int uplink_enabled;
    int usb_audio_enabled;
};

static int voice_route_start(
    struct vendor_audio *api,
    int enable_usb_audio,
    struct voice_route_state *state
);

static int voice_route_stop(
    struct vendor_audio *api,
    struct voice_route_state *state
);
```

两种传输模式分别调用：

```c
/* 现有 macOS UAC */
voice_route_start(api, 1, &route);

/* iPhone USB network after ECM/NCM validation */
voice_route_start(api, 0, &route);
```

网络模式不应启用 `f_audio`：

```text
/sys/class/android_usb/f_audio/audio_enable = 0
```

这样可以避免 iOS 抢占系统 USB Audio 路由，但不能继续假定当前 `rmnet` 组合可用；
必须先得到经过实机验证且可回滚的 ECM/NCM 组合。

### 4.2 增加网络模式参数

建议增加：

```text
--network-session
--listen-address 192.168.225.1
--audio-port 45751
--token-file /data/djonehub/pairing.key
--playback-device hw:0,5
--capture-device hw:0,6
```

实际地址和接口名必须由模块现场的 `ip -4 addr` 确认，不能写死到公网接口。

### 4.3 抽象传输层

将 `bridge_context.tty_fd` 改为通用 transport：

```c
enum transport_kind {
    TRANSPORT_TTY,
    TRANSPORT_UDP
};

struct bridge_context {
    struct vendor_audio api;
    enum transport_kind transport_kind;
    int transport_fd;
    struct sockaddr_storage peer;
    socklen_t peer_length;
    uint32_t session_id;
    uint32_t tx_sequence;
    /* 保留原有 PCM、状态和清理字段 */
};
```

把实时线程中的直接 `read(tty_fd)`/`write(tty_fd)` 替换为：

```c
transport_receive_uplink(context, buffer, size);
transport_send_downlink(context, buffer, size);
```

TTY 模式保留原行为；UDP 模式使用 `recvfrom()`/`sendto()`，只接受已经完成鉴权和 session 协商的 peer。

当前阶段 A 已在 `module/mavo_pcm_bridge.c` 中提供实验性实现：

- `--probe-network-pcm` 打开 `hw:0,5` / `hw:0,6`，核对两端实机均为 256
  字节 period，再读取 D6 约 3 秒并报告峰值与非零采样；不会启用 USB Audio 或写持久区。
- `--network-session` 要求显式提供 `--peer-address`、`--peer-port`、`--token-file`、`--interface` 和非零 `--session-id`。
- 媒体包使用 20 字节头、256 字节 PCM S16LE 载荷和 16 字节 HMAC-SHA256 标签；校验 peer、session、方向、长度、8 kHz 时间戳及递增序号。
- 网络模式当前复用 D4 VoLTE route 并跳过 `/sys/class/android_usb/f_audio/audio_enable`；
  原 D5 上行、D6 下行映射已被实通话否定，需改为经过真实方向验证的 PCM 路径。

实机已确认 D5/D6 的 period 都是 256 字节，但没有确认它们可作为网络双向媒体端点。
活动电话中的 D6 非零采样可能来自 gadget 关闭前的残留缓冲；D5 写入 -9 dBFS 测试音
后对端仍未听到。实时 DAPM 显示 `VoLTE_DL -> PCM_RX` 和
`PCM_TX -> VoLTE_UL`，与原先按 ALSA playback/capture 名称推断的方向不符。空闲态 D6
还会快速返回旧数据或零帧，任何发送循环都不能依赖 PCM read 自身节拍。这仍不是生产
完成态：当前必须先更换 PCM/mixer 映射，并且尚无抖动缓冲、
控制面握手或 iOS 客户端，session-id 需由后续控制 daemon 按通话生成。

## 5. 音频协议

第一版直接使用 PCM，不使用 Opus：

```text
采样率：8000 Hz
声道：1
格式：PCM S16LE
硬件 period：16 ms
每帧：128 samples / 256 bytes
```

USB Ethernet 的带宽足够，PCM 可以减少编码延迟和首次实现的不确定性。iOS
VoiceProcessingIO 的回调大小不保证等于 128 samples，客户端必须通过有界环形缓冲重分帧，
不能把 10 ms 或 20 ms 的宿主帧长直接强加给模块 PCM。

建议包头：

```c
struct __attribute__((packed)) audio_packet {
    uint32_t magic;          /* "DJOA" */
    uint8_t version;         /* 1 */
    uint8_t direction;       /* 1=uplink, 2=downlink */
    uint16_t payload_bytes;  /* 256 */
    uint32_t session_id;
    uint32_t sequence;
    uint32_t timestamp;      /* 8 kHz sample clock */
    uint8_t payload[256];
    uint8_t auth_tag[16];
};
```

媒体策略：

- 上下行初始抖动缓冲 40–60 ms。
- 任一方向最多保留 3 帧。
- 缺少上行包时向模块补静音。
- 队列满时丢弃最旧包，不追赶历史音频。
- sequence 用于识别乱序和丢包，timestamp 用于时钟漂移判断。
- 3 秒没有控制心跳或合法媒体包时关闭 session 并回滚。
- iPhone 端负责 48 kHz 与 8 kHz 的转换和 VoiceProcessingIO 回声消除。

## 6. PCM 设备验证

当前模块现场显示：

```text
00-00 MultiMedia1      playback/capture
00-01 VoIP             playback/capture
00-02 CS-Voice         playback/capture
00-03 Hostless         playback/capture
00-04 VoLTE            playback/capture
00-05 AFE-PROXY RX     playback
00-06 AFE-PROXY TX     capture
00-07 AFE Playback     playback
00-08 AFE Capture      capture
```

已否定的候选组合：

- D4 保持 VoLTE route session。
- D5 playback 接收 iPhone 上行 PCM（实测写入成功但对端无声）。
- D6 capture 输出运营商下行 PCM（非零数据无法排除残留上行缓冲）。
- 网络模式不启用 USB Audio。

候选调用：

```c
route_capture = pcm_open("hw:0,4", VOICE_CAPTURE_FLAGS, ...);
route_playback = pcm_open("hw:0,4", VOICE_PLAYBACK_FLAGS, ...);
uplink_pcm = pcm_open("hw:0,5", PCM_PLAYBACK_FLAGS, ...);
downlink_pcm = pcm_open("hw:0,6", PCM_CAPTURE_FLAGS, ...);
```

这组映射已经被真实通话否定。随后分别使用网络候选 helper 和固定哈希的上游 MaVo
helper 测试 MultiMedia1：无论 D4 AFE route 是否运行，`hw:0,0` playback/capture 都在
prepare 阶段返回 `EINVAL`；D4 完全退出时 Auxpcm ACDB 已校准且 legacy mixer 已恢复，
仍不改变结果。当前运行时 manifest 也没有把 D0 列为必需设备，因此 MultiMedia1 只是
保留兼容代码，不能作为本模块当前驱动的可用网络媒体入口。

新的首选方案是保留已经在 Mac 上工作的 D4 + `f_audio` UAC 媒体路径，让真实 iPhone
直接枚举模块为双向 USB Audio 设备；ECM/NCM 只承载电话控制协议。必须用真实 iPhone
确认系统枚举、`AVAudioSession` 输入/输出选择、前后台限制和连续通话。如果 iOS 不能
以应用所需方式访问该 UAC，才进入内核改造：为 `PCM_RX` 下行增加用户态 capture，为
`PCM_TX` 上行增加用户态 playback，并保持与 UAC route 互斥。不能继续通过交换 D5/D6
或猜测 ALSA 编号解决方向问题。

## 7. 控制协议

TCP 控制端口固定为 `192.168.225.1:45750`。候选协议使用紧凑二进制帧而非开放 JSON：

1. 模块每次 `accept` 后从 `/dev/urandom` 生成 32 字节 challenge，发出 HELLO。
2. 客户端发送版本、固定操作码、非零 request ID、长度受限 payload，以及覆盖
   `challenge + header + payload` 的完整 HMAC-SHA256。
3. 模块常量时间校验通过后才执行 STATUS/DIAL/ANSWER/END；每个 TCP 连接只接受一条
   请求，从而使旧连接的认证帧无法跨连接重放。
4. 模块以同一 challenge 对结构化结果签名；客户端必须同时核对 tag 与 request ID。

请求头固定 20 字节，保留字段必须为零，payload 最大 81 字节。STATUS payload 为空；
DIAL 只允许 `+0123456789*#` 且 `+` 只能出现在首位；ANSWER/END payload 是一个非零
call ID。响应只包含固定状态码、动作结果和最多 8 条定长 call snapshot。当前协议只做
身份与完整性认证，不提供内容保密；电话号码不会进入蜂窝公网监听面，但同一 USB 链路
上的明文可见性需在威胁模型中明确。如需保密，应在协议定稿前升级为具备 AEAD 的握手，
而不是在 HMAC 帧外临时加可选加密。

主动事件推送尚未定稿。第一版 iOS 客户端可短轮询 STATUS；验证 QMI indication 的线程
与回调生命周期后，再增加有界、认证的来电状态流。生产协议绝不开放通用 `/api/at`、
远程 shell 或客户端指定 QMI message ID。

## 8. 模块内部 AT 通道

这是音频修改之外的首要技术门槛。必须通过只读盘点确认：

```sh
ls -l /dev/smd* /dev/ttyGS* /dev/qcqmi*
ps | grep -E 'ril|atfwd|qmux|qmi|quectel'
cat /proc/tty/drivers
```

需要确定：

- 哪个 `/dev/smdX` 或本地 socket 是 AT 命令通道。
- 是否被 RIL 或厂商进程独占。
- 是否存在厂商 `sendat` 或 voice call API。
- USB gadget 的 `/dev/ttyGSX` 是否只是 host 侧数据端点，不能误认为内部 AT 入口。

不要随机向多个 `/dev/smdX` 写 `AT`；它们可能承载 GPS、QMI、诊断或 voice service。找不到可靠内部控制入口时，网络音频成功也只能证明音频链路，不能完成 iPhone 独立拨号。

## 9. 安全边界

模块内核和用户空间较旧，服务不得暴露到蜂窝公网：

- 使用 `SO_BINDTODEVICE` 绑定 USB Ethernet。
- 只监听模块 USB 地址，不监听 `0.0.0.0`。
- 首次部署生成 32 字节随机 pairing key，模块文件权限 `0600`。
- iPhone 将密钥保存在 Keychain。
- 控制连接使用随机 challenge 与 HMAC-SHA256。
- 媒体包携带 session ID 和认证标签。
- 禁止默认密码、远程 shell和任意 AT。
- 控制 daemon 不通过 `system()` 执行客户端参数。

## 10. 驱动和持久化

iPhone 不能在每次模块上电后通过 ADB推送运行时，因此最终需要将以下文件放入确认可持久化的模块分区：

```text
qdc507_aprv3.ko
qdc507_voice.ko
mavo-pcm-gateway.armv7
djonehubd.armv7
pairing.key
```

持久启动必须 fail closed：

1. 验证 `uname -r` 精确为 `3.18.44`。
2. 验证每个文件 SHA-256。
3. 检查没有旧驱动或活跃 PCM holder。
4. 按固定顺序加载内核模块。
5. 只启动控制 daemon，不在开机时长期打开 call route。
6. 失败时记录日志并停止，不自动刷机、不自动重启。

初期不要修改 boot、MTD 或 rootfs。先通过 ADB把文件放入 `/tmp` 做完整通话验证。确认连续多通电话稳定后，再选择已经验证可写、重启后保留的 UBI 数据分区和现有 init 机制。

## 11. 实施阶段

### 阶段 A：只改媒体传输

1. 从固定上游提取 helper 源码。
2. 重构 route start/stop。
3. 增加 UDP transport 和 PCM 探测模式。
4. 通过当前 Mac ADB临时部署到 `/tmp`。
5. 拨号仍使用现有 USB AT，通话媒体改走 USB Ethernet。
6. 做 30 秒双向通话与连续多通测试。

验收条件：双向非零、无持续积压、第二通电话正常、停止后 mixer 与 PCM 全部回滚。

### 阶段 B：迁移电话控制

1. 找到模块内部 AT/QMI 控制入口。
2. 实现 `djonehubd` 与白名单协议。
3. 让 Mac 测试客户端只通过 USB Ethernet控制电话。
4. 验证无需主机 libusb/ADB 即可拨号、接听和挂断。

### 阶段 C：iOS 前台客户端

1. SwiftUI 电话界面。
2. Network.framework 控制和 UDP 媒体。
3. AVAudioEngine/VoiceProcessingIO。
4. CallKit 通话界面。
5. 前台拨号、接听、DTMF 和连续通话验证。

### 阶段 D：持久化

1. 备份模块全部 MTD 分区和系统元数据。
2. 确认可恢复路径。
3. 将经过校验的运行时写入持久 UBI 数据分区。
4. 使用模块现有 init 机制延迟启动 `djonehubd`。
5. 断电重启、多次插拔和失败回滚验证。

## 12. iOS 后台限制

即使模块网关完成，普通 iOS App 在锁屏后仍可能被挂起。模块本地事件不能像 APNs 一样可靠唤醒已经终止或长期挂起的 App。

因此首版目标应限定为：

- App 保持前台时完整接打电话。
- 通话建立后允许进入后台并维持当前音频。

可靠锁屏来电最终仍需要 APNs/PushKit 服务、MFi ExternalAccessory 后台能力，或接受只能在 App 活跃时接听的限制。CallKit 只负责系统通话 UI 和音频会话协调，不会自动访问外接基带。

## 13. 备份要求

在任何持久化部署前必须：

- 保存 `/proc/mtd`、`/proc/partitions`、`/proc/cmdline` 和 `/proc/mounts`。
- 保存 UBI 映射、文件系统清单和设备属性。
- 读取所有 `/dev/mtdXro`，验证文件大小与 MTD 表一致。
- 为每个镜像生成 SHA-256。
- 将备份目录权限设为 `0700`、镜像权限设为 `0600`。
- 不把 EFS、usr_data、SIM/eSIM 数据、设备序列号或完整备份提交到 Git。

当前模块没有 `nanddump`，所以常规 `dd`/字符设备读取只能保存 ECC 校正后的逻辑分区内容，不包含 NAND 每页 OOB 原始字节。若未来需要芯片级坏块/OOB 恢复，应另行构建经过审核的只读 MTD dumper；不要在未验证的情况下把第三方 `nanddump` 写入持久分区。

## 14. 相关报告

- [QDC507 全量备份、EDL 排障与 SBL 恢复报告](qdc507-backup-edl-sbl-recovery-report.md)
