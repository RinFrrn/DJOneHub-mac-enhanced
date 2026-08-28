# DJOneHub UAC Probe

这是一个只使用 Apple 公共 API 的 iPhone/iPad 真机探针，用于回答一个具体问题：
QDC507 模块现有 `f_audio` USB gadget 是否会被 iOS 同时选为音频输入和输出。

探针不使用 ADB、libusb、DriverKit 或 ExternalAccessory，也不控制电话。它只通过
`AVAudioSession`：

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

当前 `djonehubd` 尚未实现，因而出现“端口未监听”是预期结果。不要把互联网可访问
误认为控制 daemon 已就绪；生产通话仍需先完成模块侧控制面和方向正确的 PCM 驱动。

若只有输入或只有输出，应先导出日志，不要修改模块持久 USB composition。若完全没有
USB Audio，下一步是核对模块 gadget descriptor 与 iPhone 枚举，不是猜测其他 ALSA
设备号。
