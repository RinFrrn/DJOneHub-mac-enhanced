# MaVo iOS 网关阶段 A 实施状态

本目录记录当前阶段的实验性实现，源码位于仓库 `module/`，来源为 MaVo
提交 `0443dfdaf8aec086fd76ba2ee9152fd908114524`。

## 已完成

- 将 `run_voice_route_session()` 拆为可复用、幂等的
  `voice_route_start()` / `voice_route_stop()`。
- 网络模式可复用 VoLTE D4 route，但不会写
  `/sys/class/android_usb/f_audio/audio_enable`，避免抢占 USB Audio。
- 增加 `--probe-network-pcm`：打开 `hw:0,5` / `hw:0,6`，核对实机 256 字节
  period，采集 D6 约 3 秒并输出 `frames`、`peak`、`nonzero_samples`。
- 增加带 HMAC-SHA256（32 字节 pairing key，包内截取 16 字节 tag）的 IPv4 UDP
  媒体模式：D5 接收上行、D6 发送下行，固定 peer、session、端口和 USB 网卡绑定。
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
- 旧 ADB sync 即使发送 mode `0100600`，落盘权限仍可能带组/其他位。pairing key 部署后
  必须显式 `chmod 600` 并 `stat` 回读；helper 会 fail closed 拒绝权限过宽的密钥。

## USB/ADB 盘点经验

macOS 可在 IORegistry 中看到 `2CA3:4006` 及 `ADB Interface`（子类 66），但系统
`adb devices` 仍可能为空，因为 DJOneHub 使用项目内 libusb 客户端直接访问该厂商
接口，而不是系统 ADB daemon。若没有 `UsbExclusiveOwner`，应继续使用 DJOneHub 的
USB ADB 路径，不要据此判断模块未连接。

## 尚未声称完成

- 尚未在活动电话中获得 D6 非零语音，也未验证 D5 确为上行；需要带对端语音的实通话。
- 当前媒体循环没有 40–60 ms 抖动缓冲，也没有控制面握手；session-id 需由后续 daemon 每通电话生成并传给双方。
- 模块当前 USB functions 为 `diag,serial,rmnet,ffs,audio`；虽然内部已有
  `bridge0=192.168.225.1/24`，但 `bridge0/brif` 为空且 macOS 没有对应 `en*` 接口。
  当前 `rmnet` 不是普通 iPhone App 可使用的 USB Ethernet，必须另行验证可回滚的
  ECM/NCM composition，IP 链路仍是阶段 A 的阻塞项。
- 电话 AT/QMI 控制、iOS `Network.framework`/`VoiceProcessingIO` 客户端、持久化启动仍未实施。
- 未写入模块持久分区，也未修改发布包。
