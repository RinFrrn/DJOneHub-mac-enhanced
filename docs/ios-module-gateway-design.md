# DJOneHub iOS 模块侧电话网关设计

## 1. 目标与结论

目标是在不依赖 Mac 或另一台常驻设备的情况下，让 iPhone 通过 USB 直连大疆第一代 4G 模块，在前台完成拨号、接听、挂断和双向通话。

当前 macOS 实现不能原样移植到 iOS：它依赖 libusb/IOKit 直接访问模块的 USB AT、ADB 和 UAC 接口，而普通 iOS App 没有这些能力。可行方向是把电话控制和语音传输移到模块内部，再通过模块已有的 USB Ethernet 向 iPhone 提供受控的网络协议。

推荐架构：

```text
模块内部
├── djonehubd                    常驻控制 daemon
│   ├── 独占并串行化 AT/QMI 控制通道
│   ├── 解析 RING、CLIP、CLCC 等状态
│   ├── 提供经过鉴权的 TCP 控制协议
│   └── 按每通电话启动/停止音频 helper
│
└── mavo-pcm-gateway             每通电话运行
    ├── 配置并回滚 VoLTE mixer
    ├── 打开模块 PCM 设备
    ├── UDP 接收 iPhone 上行 PCM
    └── UDP 发送运营商下行 PCM

USB Ethernet
└── iPhone App
    ├── Network.framework 控制和音频
    ├── AVAudioEngine/VoiceProcessingIO
    ├── CallKit 通话界面
    └── Contacts/SwiftUI
```

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

iPhone 无法执行这条 ADB 控制链，因此驱动准备、电话控制和音频 session 管理最终都必须由模块上的常驻 daemon 接管。

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

/* iPhone USB Ethernet */
voice_route_start(api, 0, &route);
```

网络模式不应启用 `f_audio`：

```text
/sys/class/android_usb/f_audio/audio_enable = 0
```

这样可继续使用当前 iPhone/iPad USB 组合，只暴露 USB Ethernet，避免 iOS 抢占系统 USB Audio 路由。

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

## 5. 音频协议

第一版直接使用 PCM，不使用 Opus：

```text
采样率：8000 Hz
声道：1
格式：PCM S16LE
帧长：20 ms
每帧：160 samples / 320 bytes
```

USB Ethernet 的带宽足够，PCM 可以减少编码延迟和首次实现的不确定性。

建议包头：

```c
struct __attribute__((packed)) audio_packet {
    uint32_t magic;          /* "DJOA" */
    uint8_t version;         /* 1 */
    uint8_t direction;       /* 1=uplink, 2=downlink */
    uint16_t payload_bytes;  /* 320 */
    uint32_t session_id;
    uint32_t sequence;
    uint32_t timestamp;      /* 8 kHz sample clock */
    uint8_t payload[320];
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

首选验证组合：

- D4 保持 VoLTE route session。
- D5 playback 接收 iPhone 上行 PCM。
- D6 capture 输出运营商下行 PCM。
- 网络模式不启用 USB Audio。

候选调用：

```c
route_capture = pcm_open("hw:0,4", VOICE_CAPTURE_FLAGS, ...);
route_playback = pcm_open("hw:0,4", VOICE_PLAYBACK_FLAGS, ...);
uplink_pcm = pcm_open("hw:0,5", PCM_PLAYBACK_FLAGS, ...);
downlink_pcm = pcm_open("hw:0,6", PCM_CAPTURE_FLAGS, ...);
```

这组映射仍需真实通话验证。应先增加 `--probe-network-pcm`：只采集 3 秒并报告 frames、peak 和 nonzero samples，不写入持久存储。确认 D6 有对端信号后，再开放 D5 上行。

## 7. 控制协议

建议 TCP 控制端口 `45750`，采用长度前缀 JSON 或 WebSocket。应用层只开放白名单：

```json
{"id":1,"op":"dial","number":"+86138XXXXXXXX"}
{"id":2,"op":"answer"}
{"id":3,"op":"hangup"}
{"id":4,"op":"dtmf","digit":"5"}
```

状态事件：

```json
{
  "event":"call",
  "state":"incoming",
  "number":"+86138XXXXXXXX",
  "session":1234
}
```

生产协议不要开放未经保护的通用 `/api/at`。电话号码只允许 `+0123456789*#`；DTMF 只允许标准字符；任何网络字符串都不能拼接进 shell 命令。

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
