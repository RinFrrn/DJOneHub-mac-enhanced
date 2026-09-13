# 模块端 Bark 与 Web Push 提醒

本实现不需要 DJOneHub 通知中转服务器。通知发送器、QMI 观察器都运行在 QDC507，
不依赖 Mac 或 iPhone App 保持前台。Bark 使用用户选择的 Bark 服务；Web Push
直接发送到浏览器订阅提供的推送端点。两者仍需要模块和手机联网。

## 本版范围

- `module/djonehub_notify_monitor.c`：只读 QMI Voice STATUS、WMS LIST/READ。
  电话查询结束后间隔 1 秒；短信完整扫描结束后间隔 10 秒。Voice/WMS 使用两个
  独立进程，短信扫描或 HTTPS 请求不会阻塞电话查询。此版是轮询，尚不是 QMI indication。
- `cmd/djonehub-notify`：管理观察器、Bark/Web Push 发送、持久去重、有限重试；仅在
  USB ECM 地址 `192.168.225.1:45753` 监听配置请求，复用控制会话 pairing key，
  每次连接使用随机 nonce 与 HMAC-SHA256 认证。它不提供 shell、AT 或任意 QMI 操作。
- `web/module-push/`：可部署在 HTTPS 静态托管上的 PWA 配对页面，无数据库或动态后端。
  订阅文件可以直接在 iOS App 的模块提醒页面导入。
- iOS App 的“设置与诊断 → 模块提醒”可读取脱敏状态、配置 Bark URL、隐私选项、
  Web Push 订阅和自定义 CA，并由模块发起测试；URL 和密钥不会回读到界面。
- 普通提醒可以提醒用户打开 DJOneHub。没有新增 CallKit 自动唤醒或锁屏接听能力。

## 通知行为

| 事件 | 处理 |
| --- | --- |
| 来电／呼叫等待 | 同一 modem call ID 的一次连续振铃只创建一个事件；25 秒有效期 |
| 电话不再振铃 | 删除待发送项，取消本机尚未完成的请求；已被第三方接收的通知无法撤回 |
| 首次扫描短信存储 | 记录已有 SMS-DELIVER 内容指纹，不推送历史短信 |
| 后续新增短信 | 内容指纹识别，避免已读标签变化、相同内容跨 SIM/NV 存储造成重复提醒 |
| 进程重启 | 恢复短信指纹和待发送队列；丢弃旧来电队列，再读取实际振铃状态 |
| QMI 查询失败 | 不生成空快照，不把已有短信误认作删除／重新收到 |
| HTTP 429／408／5xx 或网络故障 | 指数退避，最多 10 次；来电仍受 25 秒期限约束 |
| HTTP 4xx，包括过期 Web Push 订阅 404／410 | 本条不重试；需要用户重新订阅／检查配置 |

队列最多 256 条，满时优先淘汰旧短信提醒以容纳来电；短信最长保留 24 小时。
长短信支持 8 位／16 位分段头，分段收齐后按序合并，每个启用的推送服务只入队一次。
支持跨 SIM/NV 存储、乱序到达及进程重启后继续合并；首次扫描的历史分段不补发。
最多保存 128 组分段状态，24 小时过期；未收齐的分段暂不推送。
默认只发送固定的“有来电／新短信”文案。用户可分别打开 `show_call_number` 和
`show_sms_body`；号码只在调制解调器标记为允许展示时使用，短信正文会做 UTF-8 清理并限制
为 240 个字符。启用后，相应内容会交给 Bark/Web Push，也可能在等待重试时存入模块的
`0600` 状态文件（包括尚未收齐的分段正文）；关闭选项后，待重试队列和待合并分段会立即删去对应内容。原始 PDU 和短信发件人不会
进入通知队列。内容指纹使用 SHA-256。日志不记录推送地址、密钥、号码、正文或原始 HTTP 错误。

这是有重试的尽力投递：推送服务已经收到但响应丢失、或收到响应后掉电，可能重复；
服务接收成功也不代表手机已展示。静音、专注模式、通知权限、网络延迟仍影响提醒。
Bark 的 30 秒重复声音无法跟随模块挂断自动停止；可在配置中关闭 `bark_call_sound`。

## 构建与离线验证

```sh
go test -race ./internal/modulepush ./cmd/djonehub-notify
cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  module/djonehub_notify_monitor_test.c -o /tmp/notify-monitor-test
/tmp/notify-monitor-test
node --check web/module-push/app.js
node --test web/module-push/sw.test.cjs
./scripts/build_notify_armel.sh --container
```

输出：

- `outputs/module/djonehub-notify.armv7`：静态 Go，ARMv7 soft-float。
- `outputs/module/djonehub-notify-monitor.armv7`：复用模块 vendor QMI 库。
- `outputs/module/djonehub-notify-licenses/`：分发构件时需要附带的第三方许可。
- monitor 的 SHA-256 和 ABI 审计报告：拒绝 hard-float、过新 glibc、GNU-only hash、
  可执行栈及 QDC507 不兼容的标准流数据重定位。

构建需要 Go、Python 3 和 Docker。脚本通过 Go `-overlay` 将 FIPS 随机源的
32 MiB 静态缓冲区改为首次使用时分配，并用 `sync.Once` 保持并发安全；不修改本机
SDK、随机源算法或 TLS 校验。该静态保留区在本机 QDC507 的低内存环境中会导致
程序进入 Go 运行时之前就发生 SIGSEGV，`GOMEMLIMIT` 无法解决。加密功能仍使用
Go 标准库；此定制构件不声称 FIPS 认证。脚本只接受已审查的 Go 1.26.3／1.27.0
源文件指纹，未知修订会拒绝构建，需重新审查。发送器 ELF 审计额外限制 BSS 不超过
1 MiB；审计文件记录 SDK 版本、源文件指纹与最终大小。

若已有兼容的 ARM 编译器，可使用 `--local`。根目录 Go 依赖中的 `x/text` 是裁剪的
本地源码，因此全仓库 `go mod tidy` 会尝试加载缺失的第三方测试包；本功能的构建
和测试不需要 tidy，不应为此替换裁剪依赖。

## 配置 Bark

以下命令在模块上执行，或在 Mac 上以 `go run ./cmd/djonehub-notify` 替换可执行文件，
先生成私密配置，再通过项目已有的 USB ADB 传输导入模块。配置必须只属于这一台模块。

```sh
umask 077
./djonehub-notify.armv7 -init -config ./config.json
./djonehub-notify.armv7 -config ./config.json -bark-url-file ./bark-url.txt
./djonehub-notify.armv7 -config ./config.json -check
./djonehub-notify.armv7 -config ./config.json -test bark
```

`bark-url.txt` 内容应为 `https://api.day.app/你的设备密钥`，或自托管服务的同类地址。
不要带示例通知正文、查询参数。文件权限需为 `0600`；推送地址和私钥不要放在
命令行参数、Git、截图或日志里。`-init` 拒绝覆盖已有配置，防止意外轮换 VAPID 密钥。

收到“推送服务已接收”后，仍要在手机确认通知真的出现。测试通知不使用重复来电声音。

Mac 上可使用已经接入的固定操作命令部署，不依赖系统 ADB 列出设备：

```sh
go run ./cmd/djonehub-macos -module-notify install \
  -notify-config /绝对路径/config.json -notify-ca /etc/ssl/cert.pem
go run ./cmd/djonehub-macos -module-notify test-bark
go run ./cmd/djonehub-macos -module-notify probe-runtime
go run ./cmd/djonehub-macos -module-notify start
go run ./cmd/djonehub-macos -module-notify status
go run ./cmd/djonehub-macos -module-notify stop
go run ./cmd/djonehub-macos -module-notify disable-boot
```

安装先校验配置、ARM ELF、CA bundle、模块 root/QMI 环境，以及 `/usrdata` 是否能容纳
本次全部暂存文件并保留 1 MiB 余量（按实际构件大小计算）。所有文件先上传为 `.new`，回读 SHA-256，并在模块上检查配置后再替换。
已有进程运行时拒绝更新，需要先 stop。安装会创建仅指向
`/usrdata/djonehub/notify/start-on-boot.sh` 的 `/etc/rc5.d/S97djonehub-notify`
启动链接，并在操作完成或失败时把根文件系统恢复为只读；`disable-boot` 可移除本项目拥有的链接。
默认使用 6 MiB Go 软内存预算、`GOGC=25`、单核运行，日志限制为当前／上一份各 256 KiB。
内存预算不包含所有进程和运行库开销。已测得 30 秒 sender 加双观察器约 7.2 MiB RSS；
满短信存储、真实通话与音频并行时仍需测量。

也可直接在模块上运行观察器与发送器：

```sh
SSL_CERT_FILE=/usrdata/djonehub/notify/ca.pem \
GOMEMLIMIT=6MiB GOGC=25 GOMAXPROCS=1 \
LD_LIBRARY_PATH=/usr/lib \
/usrdata/djonehub/notify/djonehub-notify.armv7 \
  -config /usrdata/djonehub/notify/config.json \
  -monitor /usrdata/djonehub/notify/djonehub-notify-monitor.armv7
```

`state.json` 默认位于配置旁。状态损坏或无法持久化时进程退出，不静默丢失去重状态。
同一状态路径有文件锁，重复启动会拒绝。iOS 保存 URL、隐私选项或 Web Push 订阅后立即生效；
导入或移除自定义 CA 也会重建发送器的受信任根集合，始终保留系统 CA 且不能关闭证书验证。
使用维护中的公共 CA bundle，并确认模块 UTC 时间正确；不支持关闭证书验证。
可先运行 `-probe-network`，只对 Bark/Apple 固定入口进行 HTTPS 连通性检查，不发送通知。
`-probe-runtime` 运行 30 秒只读观察器，要求 Voice、SIM、NV 均返回多次完整快照，
统计进程内存，退出时清理专属临时状态。它完全不配置推送目标，收到真实事件也不会发出通知。

首次硬件验证应部署在 `/usrdata` 的独立验证目录，完成后删除。不要把静态 Go
构件上传到 RAM-backed `/tmp`：本次探测曾在上传后出现 shell 无法启动，通过
ADB sync 截断自己的临时构件、再删除目录后恢复。模块当时可用内存约 11 MiB，
该现象与约 6.7 MiB 的 tmpfs 占用造成的内存压力一致。
通知进程不替换现有 voice/sms daemon。正式安装的启动链接让模块断电后换接 iPhone 时
自动恢复；启动失败只写私有滚动日志，不执行重启或 USB 配置变更。

## 在 iOS App 中配置

首次把二进制、系统 CA 和启动脚本安装到模块仍需 Mac/libusb ADB。这是一次性引导；完成后，
更换 Bark、修改通知内容、导入 Web Push 或 CA、发送测试以及模块断电重启都不再依赖 Mac。

1. 在 DJOneHub iOS App 中导入当前模块的 CONTROL 配对文件并通过 USB 连接模块。
2. 打开“设置与诊断 → 模块提醒”。App 只显示 Bark 主机名和启用状态，不回读设备密钥。
3. 输入完整 HTTPS Bark URL 后保存；以后留空保存会保留现有 URL，“停用 Bark”才会删除。
4. 按需打开“来电显示号码”或“通知显示短信正文”，然后保存。
5. 自托管 HTTPS 服务可从 Files 导入一个或多个 PEM 证书，或单个 DER 证书，总计不超过
   64 KiB。模块拒绝私钥和无法解析的证书。
6. Web Push 页面导出的 `djonehub-push-subscription.json` 可从这里直接导入；公钥必须与
   页面中展示的模块公钥一致。

每个配置请求都只接受固定操作，限制报文大小并验证 HMAC。iOS App 要求 wired Ethernet，
模块端还校验连接两端处于相同 USB `/24`；普通蜂窝或互联网接口不能访问该端口。

## Web Push 最小闭环

1. 把 `web/module-push/` 作为独立静态目录部署到可信 HTTPS origin，保留相对目录结构。
   不要把含密钥的目录作为静态网站根目录。HTTP 模块管理页不能替代这个 HTTPS origin。
2. iPhone 在 Safari 打开页面，添加到主屏幕，然后从主屏幕启动。
3. 粘贴模块 `-init` 输出的 **public key**。只复制公钥；私钥保留在该模块配置中。
4. 点击“允许提醒”，导出 `djonehub-push-subscription.json`。
5. 把文件交给模块，`chmod 600` 后导入：

```sh
./djonehub-notify.armv7 -config ./config.json \
  -contact 'mailto:你的维护联系邮箱' \
  -subscription ./djonehub-push-subscription.json
./djonehub-notify.armv7 -config ./config.json -test webpush
```

也可使用 HTTPS 联系地址。导入时校验公钥匹配、P-256 密钥、订阅认证密钥及 HTTPS。
配对文件只包含订阅与公钥，不包含私钥；它仍应视为私密文件。
页面不向模块发跨源请求，避免依赖 HTTPS 页面访问模块 HTTP 地址的混合内容行为。

网页关闭后仍由推送服务投递提醒；点击通知打开网页，并提示到原生 DJOneHub 接听／查看。
过期来电如果仍被投递，显示“此前有电话呼入”，避免把旧事件展示为正在来电。
迁移 origin、清除网站数据、取消订阅、重建密钥后需要重新配对。
本版网页一份安装绑定一个模块，多模块可使用独立静态站点作用域。

## Mac 上的 QDC507 原生运行探测

系统 `adb devices` 可能看不到 QDC507；应同时检查 USB `2ca3:4006` 或 `2c7c:0125`。
本仓库有 opt-in 真机测试，使用已有 libusb ADB 实现，临时上传后校验 SHA-256，
启动 ARM Go 程序生成密钥，并分别读取一轮 Voice/SIM/NV 快照，最后清理临时目录：

```sh
DJONEHUB_LIVE_NOTIFY=1 \
DJONEHUB_NOTIFY_CA_FILE=/etc/ssl/cert.pem \
go test ./cmd/djonehub-macos -run '^TestLiveQDC507NotifyRuntime$' -v -count=1 -timeout=4m
```

运行时需要模块空闲，且没有其他进程竞争 ADB。验证目录位于 `/usrdata`，不写启动项。
输出只显示短信数量，不显示 PDU 内容。
`DJONEHUB_NOTIFY_CA_FILE` 可省略，此时跳过联网探测。

最后的手机验收还需要：Bark 实际收件、真实呼入／挂断、真实新增短信、App 挂起与锁屏、
模块断网恢复，以及正在进行的双向通话不受观察器影响。Web Push 还需要真实 HTTPS
站点和 iPhone 授权产生的订阅。没有这些结果时，不把功能标为正式可用。

## 本次验证记录（2026-09-11）

- `go test ./...`、通知包 race 检查、相关 Go vet 通过。
- C 观察器的模拟 QMI 测试及 AddressSanitizer/UndefinedBehaviorSanitizer 通过。
- Web Push 的 P-256/VAPID 签名、独立接收端解密、通知过期和点击目标测试通过。
- ARMv7 sender/monitor 编译及 ELF/ABI 审计通过。标准 Go 1.26.3／1.27.0 构件包含
  32 MiB BSS；最小同尺寸 BSS 程序与 sender 均在 QDC507 进入 `main` 前 SIGSEGV。
  使用已审查的延迟分配 overlay 后，sender 在 QDC507 原生生成 VAPID 密钥成功。
- 原生 QMI 单轮探测通过：Voice、SIM 与 NV 均返回有效 JSON 快照，未打印短信 PDU。
  30 秒并行探测收到 30 轮来电、SIM/NV 各 3 轮完整快照，未发送通知，临时状态已删除。
- 模块直接连接 `api.day.app` 和 `web.push.apple.com` 的系统 CA TLS 验证通过；30 秒 sender
  加双观察器约 7.2 MiB RSS，独立 HTTPS 探测峰值约 7.3 MiB。模块总内存约 43 MiB、
  可用约 11 MiB。
- 使用 Safari 建立真实 Apple Web Push 订阅后，模块直发三条测试消息均返回 HTTP 201；
  系统 `webpushd` 随后收到并解密消息，Safari 通知代理接收展示请求。第三次发送前已关闭
  配对页 HTTP 服务，消息仍正常抵达，确认收件阶段无需网页或 DJOneHub 中转服务常驻。
- 安装后的 `start → status → stop → status` 真机生命周期通过；新增构件已安装并运行，
  `/etc/rc5.d/S97djonehub-notify` 启动链接已校验。
- 模块配置端口可达，并使用现有 CONTROL pairing key 完成真实 HMAC 状态读取、配置保存；
  脱敏状态确认 Bark 与 Web Push 均启用，号码／正文默认关闭。
- 使用用户提供的私密 Bark URL，由模块直接发送测试并收到 Bark `200`；通过与 iOS 相同的
  配置协议再次发起测试也已成功。URL 未写入源码、日志或测试输出。
- 首次把约 6.7 MiB 构件放入 RAM-backed `/tmp` 后，adbd 无法 fork shell；通过只针对
  探测目录的 ADB sync 截断并删除恢复。后续临时探测全部使用 `/usrdata`；完成验证后才安装
  正式启动项。
- 真实来电号码、真实新增短信正文以及 iPhone Web Push 主屏幕收件仍待实机场景验收。

## 协议来源

- [Bark 官方说明](https://github.com/Finb/Bark)
- [Apple Web Push 发送接口](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)
- [WebKit：iOS 主屏幕网页推送](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)
- [RFC 8291 消息加密](https://www.rfc-editor.org/rfc/rfc8291)
