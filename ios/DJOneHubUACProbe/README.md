# DJOneHub iOS 工程

本工程现在包含两个 target：

- `DJOneHub`：正在实施的正式通话 App，自动轮询电话状态，在拨号/接听时预热 ECM PCM；
  拨号阶段开放下行并在需要时本地合成回铃，进入 conversation 后才放行麦克风上行。
- `DJOneHubUACProbe`：保留用于 USB Audio、ECM、控制协议和媒体链路诊断的实验工具。

正式 App 的架构、阶段范围和验收门槛见
[`docs/ios-app-technical-design.md`](../../docs/ios-app-technical-design.md)。

## UAC Probe

这是一个只使用 Apple 公共 API 的 iPhone/iPad 真机探针，用于回答一个具体问题：
QDC507 模块现有 `f_audio` USB gadget 是否会被 iOS 同时选为音频输入和输出。

探针 UI 不使用 ADB、libusb、DriverKit 或 ExternalAccessory；现有 UAC 页面仍只负责
音频/ECM 诊断。项目现在额外包含一个基于 `Network.framework` + `CryptoKit` 的认证电话
控制客户端库，用于连接模块 `192.168.225.1:45750`。此外还有一个严格限定为上行的
PCM 探针：iPhone 内置麦克风通过 ECM/UDP 送到模块 D5；它不是双向媒体实现。

UAC 探针通过 `AVAudioSession`：

- 激活 `playAndRecord`；
- 从 `availableInputs` 中偏好选择 `.usbAudio`；
- 也可切换到内置麦克风，单独验证“iPhone 麦克风 -> 模块 USB 输出”上行；
- 显示系统最终采用的输入和输出、UID、声道、采样率和 I/O buffer；
- 观察 route change、interruption 和 media services reset；
- 提供输入电平表；
- 显示 iPhone 当前有线 ECM 路径，并探测模块本地控制端口 `192.168.225.1:45750`；
- 仅当当前输出为 USB Audio 时，播放 0.5 秒、700 Hz、约 -24 dBFS 的测试音。

它将上下行拆开验证，是因为 iOS 17–26.1 的普通/多路 Audio Session 不能同时采集模块
USB 输入和 iPhone 内置麦克风。iOS 26.2 新增的 `dualRoute` 虽支持两个输入设备，但
Apple 当前列出的第二设备只有有线耳麦和 Bluetooth LE/HFP，不包括 USB Audio。

## 认证电话控制客户端

`DJOneHubUACProbe/Control/VoiceControlProtocol.swift` 和
`DJOneHubUACProbe/Control/VoiceControlClient.swift` 实现模块现有一次性 voice daemon 的
固定白名单协议：`STATUS`、`DIAL`、`ANSWER`、`END`、`USB_AUDIO`。每次 API 调用建立一个新的 TCP
连接，只执行一次 HELLO / request / response，然后关闭连接；连接强制使用
`.wiredEthernet`，避免同网段 Wi-Fi 抢走到模块的路由；不提供任意 AT/QMI 透传。

探针页面现在显示“模块电话控制（实验）”区域，并接入一个只读 `STATUS` 调用入口。该
区域默认保持禁用，因为生产 pairing ceremony 尚未完成。业务层可显式注入内存中的
32 字节 key；用于真机闭环的开发流程也可导入 30 天有效的 JSON 测试配对包。测试 key
按其 SHA-256 指纹隔离保存在 `AfterFirstUnlockThisDeviceOnly` Keychain 中，不进入
UserDefaults 或日志，也不提供粘贴密钥的文本框。

调用方必须注入恰好 32 字节的 pairing key：

```swift
let client = try VoiceControlClient(pairingKey: pairingKeyData)
let snapshot = try await client.status()
let dialed = try await client.dial("+18005551212")
let answered = try await client.answer(callID: 1)
let ended = try await client.end(callID: 1)
let usbAudio = try await client.usbAudio(enabled: false)
```

仓库不包含真实 key，当前探针也不会自行生成或自动持久化 key。生产配对/轮换/撤销流程
仍未设计完成；测试时只能由外部可信流程把临时 32 字节 key 注入客户端和模块一次性
daemon。不要把测试 key、设备 key 或模块持久凭据提交到仓库。

`Control/PairingKeyStore.swift` 提供 Keychain 存储边界：只接受 32 字节值，使用
`AfterFirstUnlockThisDeviceOnly`、明确禁止同步，并按稳定模块标识建立独立 account。
新导入凭据使用 v2 envelope 保存权限、创建时间和到期时间，每次恢复都会重新校验；旧
32 字节裸 key 维持只读权限，既有 v1 envelope 首次恢复时原地升级为从升级时起 30 天
有效的 v2，不改变 key/权限/模块标识，也不会要求当前用户重新导入。该迁移已完成真机
验收：保留现有 `4a424aff…` control-session 凭据安装新版后可直接进入“可以拨号”。
只有用户显式导入测试配对包时才会写入；App 启动时只读取本 App 已有的配对项。生产
配对完成后，业务层也可调用 `VoiceControlModel.configure(from:)` 将指定模块的 key
注入内存。

App 启动时会枚举本 App 自己的 Keychain 项：只有一个模块时恢复该模块；有多个模块时
要求用户选择。App 内“删除 iPhone 本机配对”只删除对应模块的 Keychain 项，不影响其他
模块，也不谎称已经撤销模块侧 key；模块侧开发凭据必须接回 Mac 后通过卸载接口清理。

客户端严格检查 20 字节大端 header、HELLO 32 字节 challenge、request ID、完整
HMAC-SHA256 tag、响应 operation 与 call snapshot。号码只允许 `0-9`、`*`、`#` 和首位
`+`，控制层最多 80 UTF-8/ASCII 字节；ANSWER/END 只接受非零 1-byte call ID。连接、
发送和接收默认各 5 秒超时，取消或超时会主动关闭 `NWConnection`。

离线协议向量测试（使用公开的确定性测试字节，不是真实 pairing key）；其中 STATUS
request/response 固定帧也由模块 C 测试读取，用于防止 Swift/C 两端格式漂移：

```sh
xcrun swiftc \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Control/VoiceControlProtocol.swift \
  ios/DJOneHubUACProbe/Tests/VoiceControlProtocolOfflineTest.swift \
  -o /tmp/djonehub-ios-protocol-test
/tmp/djonehub-ios-protocol-test
```

预期输出：`VoiceControlProtocolOfflineTest: PASS`。

上行媒体包离线向量测试：

```sh
xcrun swiftc \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Audio/UplinkAudioProtocol.swift \
  ios/DJOneHubUACProbe/Tests/UplinkAudioProtocolOfflineTest.swift \
  -o /tmp/djonehub-uplink-protocol-test
/tmp/djonehub-uplink-protocol-test
```

下行播放队列状态机测试覆盖首次预缓冲、欠载后的独立重缓冲阈值、队列上限，以及重置后
迟到 completion 不得影响新会话：

```sh
xcrun swiftc \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Audio/DownlinkPlayoutQueueState.swift \
  ios/DJOneHubUACProbe/Tests/DownlinkPlayoutQueueStateOfflineTest.swift \
  -o /tmp/djonehub-playout-state-test
/tmp/djonehub-playout-state-test
```

音频路由恢复状态机测试覆盖去抖 revision、立即暂停后的单次恢复、空闲路由变化、系统中断
接管恢复和旧 settle 回调失效：

```sh
xcrun swiftc \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Audio/AudioRouteRecoveryState.swift \
  ios/DJOneHubUACProbe/Tests/AudioRouteRecoveryStateOfflineTest.swift \
  -o /tmp/djonehub-route-recovery-test
/tmp/djonehub-route-recovery-test
```

开发测试配对包解析测试：

```sh
xcrun swiftc \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Control/VoiceControlProtocol.swift \
  ios/DJOneHubUACProbe/DJOneHubUACProbe/Control/PairingKeyStore.swift \
  ios/DJOneHubUACProbe/Tests/DevelopmentPairingBundleOfflineTest.swift \
  -o /tmp/djonehub-pairing-bundle-test
/tmp/djonehub-pairing-bundle-test
```

## 构建

无需签名的编译检查：

```sh
xcodebuild \
  -project ios/DJOneHubUACProbe/DJOneHubUACProbe.xcodeproj \
  -scheme DJOneHubUACProbe \
  -sdk iphoneos \
  -configuration Debug \
  -derivedDataPath /tmp/DJOneHubUACProbe-DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

真机安装时在 Xcode 的 Signing & Capabilities 中选择个人或开发团队，并把 bundle ID
改成该团队下唯一的值。应用不需要额外 entitlement。

## 实机判定

1. 先安装 App，但不要连接模块。
2. 确保模块由稳定电源供电，现有 D4 helper 正常并且
   `/sys/class/android_usb/f_audio/audio_enable=1`。
3. 将模块的数据口接到已解锁的 iPhone，允许 USB 配件访问。
4. 打开 App，点“下行模式：选择模块 USB 输入”。
5. 使用“下行模式”启动输入电平，验证模块电话下行能否到达 iPhone。
6. 使用“上行模式”确认当前输入为内置麦克风、输出仍为 USB，再短暂启动麦克风上行，
   验证通话对端能否听到 iPhone 麦克风。

即使两种模式分别成功，也不代表现有 UAC 能组成完整双向电话；如果切换输入后另一条
方向消失，生产实现仍需用改造后的内核 PCM 接口把双向媒体送入 ECM/NCM 协议。

## ECM 网络探针

模块切换到 `usbnet=1` 并重启后，iPhone 若显示有线网络已连接，打开“ECM 网络探针”
并点击“测试模块控制端口”。探针只建立 TCP 连接，不发送拨号或音频命令：

- “控制端口可达”：模块侧 daemon 已监听 `192.168.225.1:45750`；
- “网络可达，端口未监听”：ECM/IP 链路正常，但模块侧 daemon 尚未部署；
- “控制端口不可达”：先检查 ECM 接口、地址和模块供电。

探针与认证客户端都限定在 iOS 的 `.wiredEthernet` 路径。模块认证 daemon 的 `--once`
只会在完整认证请求已经收到且签名响应已经发出后消费；裸 TCP 探针、错误 HMAC、截断帧
和非 USB peer 均不会让一次性 daemon 提前退出。

### iPhone STATUS 一次性闭环

这只是开发测试流程，不是最终生产配对。它会在模块 `/usrdata/djonehub/voice-test/` 写入
固定哈希 daemon、短期 pairing key 和一次性启动脚本，并精准建立
`/etc/rc5.d/S99djonehub-voice-test`；启动标记只消费一次，daemon 成功载入 key 后会立即
删除模块上的 key 文件。API 在武装前先运行一次认证 STATUS 预检，并拒绝与仍处于 armed
状态的旧 sentinel 并存。

保持模块连接 Mac，使用匹配当前固定 SHA-256 的 ARM artifact 武装，并把响应直接保存成
文件，避免 key 出现在终端输出：

先运行仓库的 `scripts/install-latest-macos-backend.sh`。安装器会在交互式终端中校验
Downloads 里最新的 ARM Actions 产物，再将四个固定范围的 `.armv7` 文件缓存到
`~/Library/Application Support/DJOneHub/artifacts/`；LaunchAgent 只读取该目录，避免
macOS 因后台进程无法展示 Downloads/TCC 授权而把 `open(2)` 长时间挂起。后端仍会独立
执行编译时固定的 SHA-256 和 ELF 校验。

```sh
curl -fsS -X POST http://127.0.0.1:7575/api/ios/voice-test/arm-once \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"confirm_operation":"arm-ios-status-once"}' \
  -o "$HOME/Downloads/DJOneHub-STATUS-pairing.json"
```

先把该 JSON 交给 iPhone，在 App 中选择“导入 STATUS 测试配对包”；确认显示“已配对”后，
删除原始 JSON，再把模块换接 iPhone。此时不要运行裸 TCP 探针，直接点“读取模块通话状态”。
配对包只允许在创建后 30 天内导入，module identifier 必须等于 key 的 SHA-256 前 16 字节；
错误 endpoint、过期包和被替换的 identifier 都会被拒绝。

STATUS 闭环通过后，可武装持久开发控制会话：

```sh
curl -fsS -X POST http://127.0.0.1:7575/api/ios/voice-test/arm-session \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"confirm_operation":"arm-ios-control-session"}' \
  -o "$HOME/Downloads/DJOneHub-CONTROL-pairing.json"
```

控制会话允许认证的 `STATUS / DIAL / ANSWER / END / USB_AUDIO`，App 每秒刷新活动 call snapshot，
拨号前还会要求一次界面确认。为支持无独立供电模块从 Mac 换接 iPhone，模块会保留
control marker、`pairing.key` 和 rc5 启动链接，断电重启后自动恢复 daemon 与 PCM bridge，
直至运行下方卸载接口。原 STATUS 模式仍以
`--once --status-only` 启动，模块端会拒绝任何变更通话状态的命令，不能靠修改 App
绕过。该持久行为只属于开发部署，首次 key 仍由 Mac 注入，不是生产配对。

Probe 保留认证的 `USB_AUDIO` 诊断操作，用于读写模块固定节点
`/sys/class/android_usb/f_audio/audio_enable`。实机验证表明该节点只控制已枚举 UAC 的数据门，
不会从 USB 描述符移除音频设备，也不会让 iOS 重新选择系统输出；正式 App 因此不再显示
该开关。要让普通声音留在手机，必须先在 Mac 端选择 iPhone/iPad USB profile，使
`USBCFG` 的 UAC 位在模块下次上电时为 0；ECM 电话控制和网络 PCM 保持可用。

控制会话现在还会启动一个独立的认证 UDP 上行监听器 `192.168.225.1:45751`。监听器空闲时
不打开 PCM；首个来自 USB ECM `/24` 的合法 HMAC 包确定 peer 和随机 session ID 后，才
确认 UAC 为关闭状态、启动 D4 voice route，并且只打开 `hw:0,5` playback。iPhone 发送
8000 Hz、单声道、signed S16_LE，128 samples / 256 bytes / 16 ms 的帧；模块按固定 16 ms
节拍写 D5。连续 3 秒没有合法包时会关闭 D5、停止 D4 route、恢复进入会话前的 UAC 状态，
然后回到只监听 UDP 的空闲状态。该模式不会打开或读取 D6，也没有 TCP 音频、下行、后台
音频或 CallKit。

真机最小验证顺序：先用 STATUS 确认界面显示“通话中”，再点“开始 iPhone 麦克风上行”，
从 iPhone 旁说一段包含计数词的短句，让蜂窝对端确认内容；停止后等待至少 3 秒再挂断。
如果界面帧数持续增加而对端无声，应先收集模块 `last-start.log`，不要切回 UAC 或启用 D6。

接回 Mac 后查看状态或完整卸载：

```sh
curl -fsS http://127.0.0.1:7575/api/ios/voice-test
curl -fsS -X POST http://127.0.0.1:7575/api/ios/voice-test/uninstall \
  -H 'Content-Type: application/json' -d '{"confirm":true}'
```

卸载接口只会删除精确指向 DJOneHub 测试脚本的启动链接；遇到同名非本项目文件会拒绝。

当前模块侧已经有经过真实 STATUS/ANSWER/END 验收的认证 voice daemon 候选；
Mac 侧会用临时 key 启动它，并明确报告 `one_shot=true`、`persistent=false`。iOS 侧新增
的是该控制协议客户端和持久开发控制部署，不会建立生产 pairing。双向 ECM PCM 已完成
真机验收；生产首次配对、双端撤销、后台来电与 CallKit 生命周期仍未完成。

如果界面显示 `POSIX 错误 61`，它是 `ECONNREFUSED` 的系统表示，含义相同：ECM
链路已经到达模块，但 `45750` 没有监听进程。仓库现在提供一个仅用于闭环验证的
最小 sentinel：`module/djonehubd.c`。它只绑定 `192.168.225.1:45750` 并返回健康
响应，不会执行 AT、拨号或 PCM。必须使用匹配 QDC507 glibc 的模块 sysroot 构建，
并以前台临时方式部署；不要把它当成生产通话服务或写入持久启动分区。

```sh
MAVO_MODULE_ROOTFS=/path/to/qdc507/rootfs \
MAVO_CROSS_DEV_ROOT=/path/to/usr/arm-linux-gnueabi \
./scripts/build_djonehubd_armel.sh --module-sysroot
```

部署后重新点击探针，预期从“端口未监听”变为“控制端口可达”。如果仍为 61，先在
模块 shell 中确认进程和监听地址，再检查 `192.168.225.1` 是否仍属于 USB 网卡；不
要通过修改 USB composition 或刷写分区来“修复”端口问题。

仓库的 `.github/workflows/build-djonehubd.yml` 可通过 GitHub Actions 手动运行，生成
`djonehubd-armv7-sentinel` artifact。Action 使用静态 ARMv7 构建，适合本次临时
连通性验证；它不等价于链接 QDC507 sysroot 的生产二进制，也不会自动上传或写入模块。

### 一次性重启启动

模块从 Mac 换接 iPhone 时会断电，单纯在 `/tmp` 运行的进程会消失。经用户明确确认后，
测试版 DJOneHub 可以把固定 SHA-256 的 sentinel 写到 `/usrdata/djonehub/sentinel/`，
并建立 `/etc/rc5.d/S98djonehub-sentinel` 启动链接。启动标记会在执行前删除，所以无论
启动成功还是失败，下一次重启都不会自动重试。启动脚本不假设 USB 网卡名称；它等待
任意接口出现 `192.168.225.1`。标记消费状态和最后一次接口快照会保存在
`/usrdata/djonehub/sentinel/last-start.state` 与 `last-start.log`，接回 Mac 后可通过
`GET /api/ios/sentinel` 读取，不依赖重启即丢失的 `/tmp`。

先通过 `.github/workflows/build-sentinel-deployer-macos.yml` 生成并安装测试版 macOS
包，再保持模块连接 Mac，执行：

```sh
curl -sS -X POST http://127.0.0.1:7575/api/ios/sentinel/install-once \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"artifact_path":"/Users/rin/Downloads/djonehubd-armv7-sentinel/djonehubd.armv7"}'
```

接口会依次验证本地 ELF 与固定哈希、模块端哈希、当前启动可执行性及 TCP 监听状态；
全部通过后才短暂把根文件系统挂为可写、建立唯一启动链接并立即恢复为只读，最后创建
一次性标记。随后把模块换接 iPhone，等待最多 60 秒，再测试 `192.168.225.1:45750`。
如果仍然超时，不要直接重复武装；先接回 Mac 调用状态接口，检查 `last_start_state` 和
`last_start_log`，确认是地址未出现、可执行文件启动失败还是监听已开始。

测试结束后把模块接回 Mac并卸载：

```sh
curl -sS -X POST http://127.0.0.1:7575/api/ios/sentinel/uninstall \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true}'
```

卸载仅在启动链接仍精确指向 DJOneHub 脚本时执行；同名路径属于其他文件时会拒绝删除。
该流程不修改 MTD、SBL、内核或 USB composition，但会在验证期间写入 `/usrdata` 和一个
根文件系统符号链接，因此仍必须保留模块备份和 Mac ADB 恢复路径。

若只有输入或只有输出，应先导出日志，不要修改模块持久 USB composition。若完全没有
USB Audio，下一步是核对模块 gadget descriptor 与 iPhone 枚举，不是猜测其他 ALSA
设备号。
