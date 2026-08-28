# MaVo iOS 网关阶段 A 实施状态

本目录记录当前阶段的实验性实现，源码位于仓库 `module/`，来源为 MaVo
提交 `0443dfdaf8aec086fd76ba2ee9152fd908114524`。

## 已完成

- 增加可编译的 iOS 17+ SwiftUI 真机探针 `ios/DJOneHubUACProbe`。它只使用
  `AVAudioSession` / `AVAudioEngine` 公共 API，显示 current route、available inputs、
  端口 UID、声道、采样率、I/O buffer 和路由事件；可分别验证 USB 下行输入、USB
  测试音上行、“内置麦克风 -> USB 输出”以及“USB 输入 -> iPhone 扬声器”。测试音、
  麦克风转发和扬声器转发均有实际路由门禁，不会在目标输出不存在时启动。
- 已在真实 iPhone 18,4 / iOS 27.0 + QDC507 `BAIWANG` UAC 上验证模块可枚举为双向
  USB Audio：AC Interface 输入、AS Interface 输出，单声道，空闲双 USB 路由为 8 kHz
  / 23 ms。内置麦克风 + USB 输出组合也可建立，输入 PCM 为 48 kHz、单声道、非交错
  Linear PCM，`AVAudioEngine` 转发时 dBFS 随说话变化。
- 已实测扬声器覆盖行为：请求“USB 输入 + iPhone 扬声器”后，iOS 把当前输入同时切为
  内置麦克风；模块 USB 输入仅留在 availableInputs 且报告 0 ch。因此 UAC 两个方向
  不能在一个 iOS Audio Session 中组成全双工电话。
- 已修复探针路由竞态：route/available-inputs 通知后等待 500 ms 稳定窗口，转发前重建
  `AVAudioEngine`，避免 8 kHz/48 kHz 节点残留触发 `-10868` 崩溃。
- 使用 Xcode 27 / iPhoneOS 27 SDK、deployment target iOS 17，对探针执行 arm64
  `CODE_SIGNING_ALLOWED=NO` 构建，结果 `BUILD SUCCEEDED`。CoreSimulator 在当前沙箱
  无法连接不影响 iphoneos 设备编译。
- 复核并实测 iOS Audio Session 路由能力后确认：现有模块 UAC 不能单独承载完整 iPhone
  手持通话。普通/传统 multiroute 不能并行取得模块 USB 输入与内置麦克风；扬声器覆盖又会
  把 USB 输入替换为内置麦克风。iOS 26+ `dualRoute` 的第二设备类型也不包含 USB。
  探针因此用于拆向实测，不再作为生产媒体架构本身。

- 将 `run_voice_route_session()` 拆为可复用、幂等的
  `voice_route_start()` / `voice_route_stop()`。
- 网络模式可复用 VoLTE D4 route，但不会写
  `/sys/class/android_usb/f_audio/audio_enable`，避免抢占 USB Audio。
- 增加 `--probe-network-pcm`：打开 `hw:0,5` / `hw:0,6`，核对实机 256 字节
  period，采集 D6 约 3 秒并输出 `frames`、`peak`、`nonzero_samples`；该探针只能描述
  AFE proxy 数据，不能单独证明电话上下行方向。
- 增加带 HMAC-SHA256（32 字节 pairing key，包内截取 16 字节 tag）的 IPv4 UDP
  媒体模式，固定 peer、session、端口和 USB 网卡绑定。协议与节拍实现已通过回归，
  但其中 D5 上行、D6 下行的 PCM 映射已被实通话否定，当前不能用于双向通话。
- 严格拒绝未提供 peer、token、interface 或 session-id 的网络启动。
- 包校验包含 magic、版本、方向、长度、session-id、peer 地址/端口、认证标签和递增序号。
- 256 字节帧使用 8 kHz sample-clock 时间戳；下行即使 PCM read 在空闲态快速返回，
  也由单调时钟限制为每 16 ms 一包。
- 媒体心跳 3 秒超时，退出时关闭网络 PCM、UDP socket 并逆序回滚 VoLTE route。

## 验收结果

- 主机严格 C11 语法检查通过（仅保留原有 Apple Clang 的动态 `vsnprintf` 提示）。
- Clang 静态分析通过，无诊断项。
- HMAC-SHA256 已知向量通过。
- 音频包认证/篡改检测单测通过。
- fake vendor 库下 D6 探测 3 秒回归通过。
- 已在 WSL Ubuntu 26.04 使用 `arm-linux-gnueabi-gcc 15.2.0`，通过真实模块
  glibc 2.22 sysroot 构建 ARMv7 soft-float 产物；连续两次构建逐字节一致。
- release ELF 仅直接依赖 `libpthread.so.0`、`libdl.so.2`、`libc.so.6` 和
  `ld-linux.so.3`，最高符号版本为 `GLIBC_2.17`。
- 已通过项目同等的直连 libusb ADB 将候选产物临时推送到模块 `/tmp`，模块端
  SHA-256 一致，`--check` 成功解析 `libql_lib_audio.so.1` 全部必需符号；随后已删除
  临时文件。该测试没有打开 PCM、修改 mixer、启动 D4 route 或写入持久分区。
- 已在真实模块加载固定哈希的 QDC507 语音驱动并运行探测。D5 playback 与 D6
  capture 均报告 256 字节 period；探测后 D4/D5/D6 全部为 `closed`，且
  `audio_enable` 保持 0。无活动通话时 D6 为全零，不能据此确认实际语音方向。
- loopback 网络会话在没有合法上行 HMAC 包时按预期 3 秒超时；期间收发各 188 个
  256 字节媒体包，与 16 ms 节拍吻合。退出后 D4/D5/D6 全部关闭，USB Audio 仍为 0。
- 已在活动电话中让对端持续说话，并对 D6 做 3 秒只读采样。USB gadget 音频释放后，
  D5/D6 均由 `RUNNING` 变为 `closed`；探测得到 `peak=11788`、
  `nonzero_samples=23515`。后续 DAPM 拓扑证明 D6 位于 `PCM_TX`/VoLTE 上行输入侧，
  且该 PCM 空闲读取不会按时钟推进，因此这些非零值可能是 gadget 关闭前的残留环形
  缓冲，不能作为运营商下行证据。原先的下行确认结论已撤回。
- 已在同一活动电话中通过模块自带 `aplay` 向 D5 写入 0.4 秒、600 Hz、峰值约
  -24 dBFS 的限幅测试音，并再次写入 1 秒、700 Hz、约 -9 dBFS 的测试音；D5 两次均
  完整播放，但通话对端均未听到。实时 DAPM 显示 D5 位于 `PCM_RX` 一侧，而 VoLTE
  上行是 `PCM_TX -> VoLTE_UL`，因此 D5 不是可直接写入的蜂窝上行端点。

## ARM 构建记录

Ubuntu 26.04 自带交叉工具链的普通 `--local` 构建会引入 `GLIBC_2.34` 和
`GLIBC_2.38`，不能部署到模块。它还默认定义 `_TIME_BITS=64` 与
`_FILE_OFFSET_BITS=64`，会生成模块 glibc 2.22 不提供的 `fcntl64` 引用。因此不能只看
“ELF32 ARM”就部署。

本次采用以下可审计输入：

- 同一台模块备份中的 `system.bin`，只读提取 `rootfs` 和 glibc 2.22 运行库；
- Debian `libc6-dev-armel-cross_2.31-9cross4_all.deb` 的头文件、启动对象和
  `libc_nonshared.a`；包 SHA-256 为
  `8d44aed7bbb6ea37ab2949df4e81b4dbcb7719f5c6469ad52d5e0481aa08c8ca`；
- WSL 的 `arm-linux-gnueabi-gcc 15.2.0` 与 binutils 2.46；
- helper 源码 SHA-256：
  `a8d2fd33be96e9418963c4756e380c6d7f4460e712371dc458fc2c95c080b404`。

构建脚本新增显式的模块 sysroot 模式：

```sh
OUT_DIR=/private/build-output \
MAVO_MODULE_ROOTFS=/private/extracted-system/rootfs \
MAVO_CROSS_DEV_ROOT=/private/bullseye-dev/usr/arm-linux-gnueabi \
./scripts/build_pcm_bridge_armel.sh --module-sysroot
```

脚本在该模式下强制保留目标的 32 位 time/off_t ABI，使用模块自身共享库链接，并执行
ELF 类别、ARMv7、soft-float、解释器、RELRO、NOW、非可执行栈、直接依赖、导出函数、
厂商符号字符串和 GLIBC 上限审计。

本次正式候选产物保存在仓库外的私有构建目录，未提交或打包进公开发布物：

| 文件 | SHA-256 |
|---|---|
| `mavo-pcm-bridge.armv7` | `7c8811d9787a05fc13ae88e2e5f602268426ef1027ccbc5b87023674ec60c049` |
| `mavo-pcm-bridge.armv7.debug` | `1e3561b1689789c91edda132f7ab63c514d8a9c4e9bfe9d5f48c33bbdbad976e` |
| `mavo-pcm-bridge.armv7.audit.txt` | `ef63308ccdad6882cb1d04d225a3e06393b326f904c28fcd4e57544fff47c0e9` |

### 构建踩坑

- Docker Hub 在本次 WSL 网络中不可达，不能把镜像拉取失败误判为源码问题。
- GitHub raw 大文件线路很慢；官方 `debuerreotype/docker-debian-artifacts`
  `dist-amd64` 分支的稀疏 Git 克隆明显更快。使用的提交为
  `bae6d64d90b4068b09ff9d8b564c2773ef5d8d83`，Bullseye OCI rootfs 层摘要为
  `94b0efe6d4f788b1b894c04a6c6885d53a41bcd0b85757fffacd2bc4de142847`。
- WSL 的 `docker` 实际是 Windows Docker Desktop 的 `docker.exe`。长时间 APT 输出会
  缓冲，不能仅凭一段时间无日志判定容器卡死。
- UBI Reader 在无 root 环境提取设备节点会报告 `Operation not permitted`；普通文件、
  共享库和符号链接仍可完整提取。本次只需要 sysroot，没有把这些警告当成镜像损坏。
- macOS 系统 `adb devices` 加入 DJI VID 后仍为空；最终继续使用项目采用的直连
  libusb ADB 协议完成自检，标准 ADB daemon 不是可靠诊断入口。
- 初版把网络 PCM period 按常见 20 ms 音频帧假设为 320 字节，实机立即报告
  `period_bytes=(256,256)` 并安全拒绝。D5/D6 实际为 128 samples、16 ms；协议载荷
  必须服从硬件 period，iOS 音频侧另做重分帧，不能反过来强迫驱动使用 20 ms。
- 空闲态 D6 的 3 秒直接探测曾返回 9759 个全零帧，证明 `quec_read_pcm()` 不能充当
  网络时钟。加入单调时钟 pacer 后，同样 3 秒 loopback 会话稳定为 188 包，没有静音洪泛。
- 活动 USB Audio 会通过 gadget 占用 D5/D6；即使 helper 的 `/proc/<pid>/fd` 只有 D4，
  ALSA status 仍会把 D5/D6 的 owner 关联到该 route，第二个 PCM open 返回 `EBUSY`。
  因此不能在现有 UAC 会话旁边并行探测网络 PCM。实测采用带退出 trap 的临时脚本，
  只把 `audio_enable` 从 1 短暂切到 0，保留既有 AFE mixer，完成只读采样后立即写回 1。
  这是诊断手段，不是生产切换协议。
- 模块自带 `aplay` 不是桌面版 ALSA CLI：选项名不同，而且即使传入采样格式仍要求
  RIFF/WAV。它还会截断较长输入路径；`/tmp/mavo-live-probe/uplink-600hz.pcm` 被截为
  不存在的路径。最终使用短路径 `/tmp/u.wav` 和标准 44 字节 WAV 头才成功播放。
- 不能用 ALSA 设备编号推断逻辑方向。实机 DAPM 明确显示
  `VoLTE_DL -> AFE_PCM_RX_Voice Mixer -> PCM_RX` 与
  `PCM_TX -> VoLTE_Tx Mixer -> VoLTE_UL`。D5 playback 写入 `PCM_RX` 不会进入上行；
  D6 capture 读取 `PCM_TX` 也不能直接当作蜂窝下行。
- 已通过 BusyBox `script` 创建伪终端，让现有 helper 使用真实 `quec_pcm_open()` 尝试
  `hw:0,0`。在 D4 AFE route 仍运行时，D0 playback 和 capture 都在 prepare 阶段返回
  `EINVAL`；退出后 D0 关闭、两个 MultiMedia1 mixer 恢复 off，原 D4 route 正常。
  此后又在 D4 完全退出、`audio_enable=0`、Auxpcm ACDB 已校准的状态下，分别用候选
  helper 与固定哈希的上游 MaVo helper 重试；D0 双向仍全部 `EINVAL`。当前运行时
  manifest 本来也只要求 D4/D5/D6，不要求 D0，因此保留的 MultiMedia1 默认模式不能
  作为当前 QDC507 UAC 驱动上的可用网络媒体入口。
- 旧 ADB sync 即使发送 mode `0100600`，落盘权限仍可能带组/其他位。pairing key 部署后
  必须显式 `chmod 600` 并 `stat` 回读；helper 会 fail closed 拒绝权限过宽的密钥。

## USB/ADB 盘点经验

macOS 可在 IORegistry 中看到 `2CA3:4006` 及 `ADB Interface`（子类 66），但系统
`adb devices` 仍可能为空，因为 DJOneHub 使用项目内 libusb 客户端直接访问该厂商
接口，而不是系统 ADB daemon。若没有 `UsbExclusiveOwner`，应继续使用 DJOneHub 的
USB ADB 路径，不要据此判断模块未连接。

## 尚未声称完成

- D5/D6 的候选双向映射已被实通话否定；D6 非零样本不能归因为下行，D5 测试音也没有
  到达通话对端；D0/MultiMedia1 在当前运行时也无法 prepare。Apple API 约束又否定了
  “UAC 全媒体、网络只控制”的完整 iPhone 通话方案。下一步必须修改内核驱动暴露方向
  正确的用户态 PCM，并验证可回滚的 ECM/NCM；不能继续靠猜测 ALSA 设备号实现。
- iOS 探针已在真实 iPhone + QDC507 模块上完成 UAC 枚举和拆向验证；尚未声称它能在
  一个 Audio Session 中完成全双工蜂窝通话。
- iOS ECM 探针已确认 `POSIX error 61` 为 `ECONNREFUSED`：iPhone 到
  `192.168.225.1` 的网络链路可达，但模块侧 `45750` 没有监听进程。已新增
  `module/djonehubd.c` 及构建脚本作为仅返回健康响应的临时 sentinel；它不执行 AT、
  不驱动 PCM，也不应注册为持久启动服务。sentinel 验证通过后，才能继续实现生产
  `djonehubd` 的配对认证、AT 串行化和通话状态机。
- 当前媒体循环没有 40–60 ms 抖动缓冲，也没有控制面握手；session-id 需由后续 daemon 每通电话生成并传给双方。
- 模块基线 USB functions 为 `diag,serial,rmnet,ffs,audio`；2026-08-28 通过临时
  `usbnet=1` 已在 Mac 上验证 ECM，新增 `en10` 并获得 `192.168.225.28/24`，
  IORegistry 显示 AppleUserECM 控制/数据接口，同时保留 USB AT、ADB 与 UAC。
  这只证明 Mac 侧 ECM 枚举和 DHCP 成功；NCM 及 iPhone 侧网络访问仍未验证，恢复目标
  是原始 `usbnet=0`。
- 电话 AT/QMI 控制、iOS `Network.framework`/`VoiceProcessingIO` 客户端、持久化启动仍未实施。
- 未写入模块持久分区，也未修改发布包。
