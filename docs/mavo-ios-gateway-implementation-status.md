# MaVo iOS 网关阶段 A 实施状态

本目录记录当前阶段的实验性实现，源码位于仓库 `module/`，来源为 MaVo
提交 `0443dfdaf8aec086fd76ba2ee9152fd908114524`。

## 已完成

- 将 `run_voice_route_session()` 拆为可复用、幂等的
  `voice_route_start()` / `voice_route_stop()`。
- 网络模式可复用 VoLTE D4 route，但不会写
  `/sys/class/android_usb/f_audio/audio_enable`，避免抢占 USB Audio。
- 增加 `--probe-network-pcm`：打开 `hw:0,6`，要求 320 字节帧，采集约 3 秒并输出
  `frames`、`peak`、`nonzero_samples`。
- 增加带 HMAC-SHA256（32 字节 pairing key，包内截取 16 字节 tag）的 IPv4 UDP
  媒体模式：D5 接收上行、D6 发送下行，固定 peer、session、端口和 USB 网卡绑定。
- 严格拒绝未提供 peer、token、interface 或 session-id 的网络启动。
- 包校验包含 magic、版本、方向、长度、session-id、peer 地址/端口、认证标签和递增序号。
- 媒体心跳 3 秒超时，退出时关闭网络 PCM、UDP socket 并逆序回滚 VoLTE route。

## 验收结果

- 主机严格 C11 语法检查通过（仅保留原有 Apple Clang 的动态 `vsnprintf` 提示）。
- Clang 静态分析通过，无诊断项。
- HMAC-SHA256 已知向量通过。
- 音频包认证/篡改检测单测通过。
- fake vendor 库下 D6 探测 3 秒回归通过。
- ARMv7 交叉编译尚未执行：当前环境没有 `arm-linux-gnueabi-gcc`，Docker 构建也受环境用量限制。

## USB/ADB 盘点经验

macOS 可在 IORegistry 中看到 `2CA3:4006` 及 `ADB Interface`（子类 66），但系统
`adb devices` 仍可能为空，因为 DJOneHub 使用项目内 libusb 客户端直接访问该厂商
接口，而不是系统 ADB daemon。若没有 `UsbExclusiveOwner`，应继续使用 DJOneHub 的
USB ADB 路径，不要据此判断模块未连接。

## 尚未声称完成

- 尚未在真实模块上验证 D5/D6 的方向和 320 字节 buffer；必须先运行探测模式。
- 当前媒体循环没有 40–60 ms 抖动缓冲，也没有控制面握手；session-id 需由后续 daemon 每通电话生成并传给双方。
- 电话 AT/QMI 控制、iOS `Network.framework`/`VoiceProcessingIO` 客户端、持久化启动仍未实施。
- 未写入模块持久分区，也未修改发布包。
