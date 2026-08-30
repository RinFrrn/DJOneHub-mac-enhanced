# DJOneHub UAC Probe

这是一个只使用 Apple 公共 API 的 iPhone/iPad 真机探针，用于回答一个具体问题：
QDC507 模块现有 `f_audio` USB gadget 是否会被 iOS 同时选为音频输入和输出。

探针 UI 不使用 ADB、libusb、DriverKit 或 ExternalAccessory；现有 UAC 页面仍只负责
音频/ECM 诊断。项目现在额外包含一个基于 `Network.framework` + `CryptoKit` 的认证电话
控制客户端库，用于连接模块 `192.168.225.1:45750`，但没有把它描述成 iOS 双向媒体实现。

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
固定白名单协议：`STATUS`、`DIAL`、`ANSWER`、`END`。每次 API 调用建立一个新的 TCP
连接，只执行一次 HELLO / request / response，然后关闭连接；连接强制使用
`.wiredEthernet`，避免同网段 Wi-Fi 抢走到模块的路由；不提供任意 AT/QMI 透传。

探针页面现在显示“模块电话控制（实验）”区域，并接入一个只读 `STATUS` 调用入口。该
区域默认保持禁用，因为生产 pairing ceremony 尚未完成；只有业务层显式调用
`VoiceControlModel.configure(pairingKey:)` 注入内存中的 32 字节 key 后才会启用读取。
UI 不提供粘贴密钥的文本框，也不会把 key 写入 UserDefaults、Keychain 或日志。

调用方必须注入恰好 32 字节的 pairing key：

```swift
let client = try VoiceControlClient(pairingKey: pairingKeyData)
let snapshot = try await client.status()
let dialed = try await client.dial("+18005551212")
let answered = try await client.answer(callID: 1)
let ended = try await client.end(callID: 1)
```

仓库不包含真实 key，当前探针也不会自行生成或自动持久化 key。生产配对/轮换/撤销流程
仍未设计完成；测试时只能由外部可信流程把临时 32 字节 key 注入客户端和模块一次性
daemon。不要把测试 key、设备 key 或模块持久凭据提交到仓库。

`Control/PairingKeyStore.swift` 已提供生产配对完成后的 Keychain 存储边界：只接受 32 字节
值，使用 `AfterFirstUnlockThisDeviceOnly`、明确禁止同步，并要求使用经过认证的稳定模块
标识建立独立 Keychain account，避免不同模块互相覆盖；它支持读取、原子更新和撤销。
当前探针不会自动调用它，也不会因该文件存在而改变临时调试流程。配对完成后，业务层
可显式调用 `VoiceControlModel.configure(from:)` 将已保存的 key 注入内存。

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

当前模块侧已经有经过真实 STATUS/ANSWER/END 验收的一次性认证 voice daemon 候选；
Mac 侧会用临时 key 启动它，并明确报告 `one_shot=true`、`persistent=false`。iOS 侧新增
的是该控制协议客户端，不会部署 daemon、写模块持久分区或建立生产 pairing。生产通话
仍缺方向正确的双向 PCM 媒体平面。

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
