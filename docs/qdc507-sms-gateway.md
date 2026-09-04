# QDC507 短信认证网关

## 目标与边界

短信网关是独立于电话控制与 PCM 媒体链路的模块端进程。它通过 QDC507 已有的
Qualcomm QMI WMS 服务访问短信，不经过 USB UAC，也不改变已经验证的 Voice DSP、
PCM bridge 或 USB Audio gate。

- 监听：`192.168.225.1:45752/TCP`，固定绑定模块 ECM `bridge0`。
- 认证：复用 `/usrdata/djonehub/pairing.key` 的 32 字节密钥。
- 网络范围：只接受 `192.168.225.0/24` 内除模块自身以外的 USB host。
- 单连接事务：32 字节新随机 challenge、一个 HMAC-SHA256 请求、一个
  HMAC-SHA256 响应，然后关闭连接。
- 不提供 shell、AT 命令、任意 QMI message ID 或任意 TLV 透传。
- 与 voice daemon 使用不同端口和魔数；短信故障不能占用 `45750` 或影响通话。

## 固定操作

协议版本 1 的 magic 为 `DJOS`（大端 `0x444a4f53`）。固定操作如下：

| 操作 | 作用 | 是否修改模块状态 |
|---|---|---|
| `STATUS` | 建立 WMS client，并返回实机 IDL 版本 | 否 |
| `LIST` | 按 NV 或 SIM 存储列出消息索引与标签 | 否 |
| `READ` | 按存储与索引读取原始 3GPP PDU | 否 |
| `SEND_RAW` | 发送一个已认证客户端生成的 GSM/WCDMA PDU | 是 |
| `DELETE` | 按存储与索引删除一条短信 | 是 |

`--read-only` 启动模式禁止 `SEND_RAW` 和 `DELETE`。网关当前只接受 WMS
GSM/WCDMA point-to-point format `0x06`；PDU 上限为 512 字节。长短信分段、地址编码、
GSM 7-bit/UCS-2 解码及合并属于可信客户端职责，模块不执行文本或号码解释。

## QMI WMS 映射

| 网关操作 | QMI WMS message ID |
|---|---|
| `STATUS` | 建立 WMS client，不发送可选 modem 查询 |
| `LIST` | List Messages `0x0031` |
| `READ` | Raw Read `0x0022` |
| `SEND_RAW` | Raw Send `0x0020` |
| `DELETE` | Delete `0x0024` |

`LIST` 的首选请求不是手工拼接 TLV：网关把与本机 WMS IDL 匹配的请求结构交给 vendor
`qmi_client_message_encode`，再将编码结果交给 raw sender。这样避免不同 WMS IDL 修订中
可选 tag/mode TLV 布局差异。旧布局仅保留为兼容回退。`DELETE` 仍兼容 index/mode 的两种
已知布局，`READ` 兼容带 tag 和不带 tag 的 WMS raw-message 返回值。所有 QMI 服务结果
TLV 都必须被解析并确认为成功，不能只以 CCI transport 返回值判断成功。

模块 vendor `libqmiservices.so.1` 不提供编译期头文件，因此运行时解析固定符号
`wms_get_service_object_internal_v01`。实机已确认 service object 为 major/minor/tool
`1/24/6`。`STATUS` 中 protocol 与 transport registration 当前固定返回 `0xff`（未知）：
这两项是可选诊断值，QDC507 的对应查询不稳定，不能用它们阻断短信读写能力判断。

## iOS 客户端现状

“信息”页已接入独立的认证客户端，复用现有 pairing key，经 wired Ethernet 直连
`192.168.225.1:45752`。页面刷新流程固定为 `STATUS -> LIST(SIM) -> LIST(NV) -> READ`，
并在本机解码 SMS-DELIVER 的 GSM 7-bit、UCS-2 或 8-bit 文本；原始 PDU、存储位置、索引、
tag 和 format 仍可在详情页核对。

当前持久会话以 `--read-only` 运行，iOS 页面也不显示发送或删除入口。模块协议虽然预留
`SEND_RAW`/`DELETE`，但必须先完成真实收件和读取验证，再做发送闭环，不能把尚未实机
验收的能力呈现为可用。

## 数据限制

- 单个请求认证载荷：最多 515 字节。
- 单个响应认证载荷：最多 1024 字节。
- 单条 PDU：最多 512 字节。
- 单次列表：最多 128 条，跨 tag 去重。
- 存储类型只允许 `0`（SIM）或 `1`（NV）。
- response HMAC 同时覆盖 challenge、header、operation、request ID 与 payload。

## 构建与验证

宿主机测试：

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror \
  module/djonehub_crypto.c module/djonehub_sms_protocol.c \
  module/djonehub_sms_protocol_test.c -o /tmp/sms-protocol-test
/tmp/sms-protocol-test

cc -std=c11 -O2 -Wall -Wextra -Werror \
  module/djonehub_wms_codec.c module/djonehub_wms_codec_test.c \
  -o /tmp/wms-codec-test
/tmp/wms-codec-test
```

ARMv7 构建：

```sh
./scripts/build_sms_daemon_armel.sh --container
```

输出为 `outputs/module/djonehub-sms-daemon.armv7`，构建脚本会拒绝 hard-float、
可执行栈、GNU-only hash、超过 QDC507 glibc 2.22 的符号版本和错误 ELF 架构。

## 实机验证记录（2026-09-05）

- HMAC 认证 `STATUS` 成功，WMS IDL 为 `1/24/6`。
- NV (`1`) 与 SIM (`0`) 的认证 `LIST` 均成功。
- 本次测试时两个存储均为空，因此尚无可用于 `READ` 的真实索引。
- 未调用 `SEND_RAW` 或 `DELETE`，未改变模块短信存储。
- 当前 ARMv7 构件 SHA-256：
  `61d314497a20a69fb7c762da9e9881d926ab5516f2bd5e3d8679a1ab76628f75`。

## 后续最小验收顺序

1. 只部署到 `/usrdata/djonehub/voice-test/`，不建立开机持久化链接。
2. 以 `--read-only` 启动，使用现有 pairing key 完成一次 `STATUS`。
3. 向模块号码发送一条内容可识别的单段测试短信，不需要重新生成或导入 pairing 文件。
4. 分别对 NV (`1`) 和 SIM (`0`) 做 `LIST`，对新增索引做 `READ`；在 iOS 信息页核对
   发件人、正文、存储位置和原始 PDU。
5. 再使用专门测试号码从模块发送一条单段短信；先保留原始 PDU 和 QMI message ID，再由对端
   确认内容。此步骤才启用完整权限。
6. 删除仅针对本次测试短信的精确 storage/index，并在删除前后各做一次 `LIST`。
7. 同时拨打一通电话，确认 voice control `45750` 和 PCM 帧计数不受短信 daemon
   启停或 WMS 请求影响。

在完成一次真实接收与 `READ` 之前，iOS 信息页只作为诊断性只读界面；在完成一次真实发送
闭环之前，不对用户暴露发送按钮。
