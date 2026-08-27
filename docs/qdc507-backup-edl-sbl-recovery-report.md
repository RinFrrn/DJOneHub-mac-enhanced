# QDC507 全量备份、EDL 排障与 SBL 恢复报告

日期：2026-08-27  
对象：大疆第一代 4G 模块 QDC507 / Baiwang，Qualcomm MDM9207  
结果：模块已恢复正常启动；完整逻辑 NAND 备份、文件系统快照、恢复工具和校验清单均已保存并验证。

## 1. 报告目的

这份报告记录一次真实 QDC507 模块备份与救援过程，重点不是提供“盲刷教程”，而是保留以下信息：

- 如何在正常 Linux 运行态和 Qualcomm EDL 模式下分别取得互补备份；
- 如何确认 NAND 几何、真实容量、分区布局和镜像边界；
- 模块固定停留在 `05c6:9008` 后，如何逐步排除临时重启状态和启动原因寄存器；
- 为什么 Streaming 分区写入一直失败；
- 如何发现可工作的 NAND Firehose programmer；
- 如何把写入范围严格限制在本机 SBL，并在复位前完成独立回读校验；
- 过程中踩过的坑、出现过的误判，以及下一次应采用的更安全流程。

本文不会公开设备序列号、OEM PK hash、EFS、射频校准数据、SIM/eSIM 信息或完整模块镜像。完整备份只保存在私有目录。

## 2. 最终结论

### 2.1 已验证结果

- 正常模式 USB：`2ca3:4006`，产品名 `Baiwang`。
- EDL 模式 USB：`05c6:9008`，产品名 `QHSUSB__BULK`。
- SoC：Qualcomm MDM9207 / 9x07。
- NAND：128 MiB，1024 个擦除块。
- 页大小：2048 字节。
- 每块页数：64。
- 擦除块大小：131072 字节。
- SBL 位于擦除块 0–9，即原始页 0–639，长度 1,310,720 字节。
- 故障时 Firehose 原始回读的 SBL 为擦除态。
- 使用同一台模块正常运行时保存的 `mtd0-sbl.bin` 写回页 0–639 后，回读镜像与源文件逐字节一致。
- Firehose 复位后，模块从 `05c6:9008` 重新枚举为 `2ca3:4006`。
- DJOneHub 成功重新打开 USB AT bridge，后台和 Notifier 均恢复运行。

### 2.2 直接故障原因与未知项

已经证实的直接启动故障是：SBL 所在页 0–639 在恢复前处于全 `0xff` 擦除态，Boot ROM 因此只能停留在 EDL。

没有足够证据确定 SBL 最初在哪一步被擦除。第一批带分区名的 `edl w` 尝试在 `0x19` 分区表提交阶段就返回错误，section header 和镜像数据均未发送，因此不能把擦除归因于这些已记录的失败写入命令。

这一区分很重要：

- “SBL 为空导致固定 9008”是经过原始回读、恢复写入、写后回读和成功启动共同验证的事实。
- “某个具体命令擦除了 SBL”在缺少写前逐页 Firehose 证据的情况下只是推测，不应写成结论。

### 2.3 模块硬件是否损坏

最终 Firehose 能稳定读取、写入并逐字节回读 NAND，写回后模块能够完整启动。这说明本次故障不是已证实的 NAND 控制器或 USB 硬件损坏，而是可恢复的启动分区内容缺失。

## 3. 安全边界

本次恢复满足以下约束：

1. 用户明确授权擦写本机 SBL，并接受进一步变砖的风险。
2. 写入来源是同一台模块在正常 Linux 运行态取得的 SBL，不是其他模块或网络固件包。
3. 写入前核对了 NAND 几何、SBL 偏移、SBL 长度和备份哈希。
4. 没有覆盖或重写 MIBIB 分区表。
5. 没有写入 EFS2、RAWDATA、sec、TZ、RPM、aboot、boot、system、usr_data 等其他分区。
6. 写入后先回读验证，再执行复位。

任何其他设备都不能直接复用本报告中的 SBL 镜像。SBL、EFS、RAWDATA、sec 和射频数据应视为设备绑定资产。

## 4. 备份总体策略

单一通道无法得到完整且可信的备份，因此采用“运行态 + EDL”互补方式。

### 4.1 正常 Linux 运行态

正常模式适合保存：

- `/proc/mtd`、`/proc/partitions`、`/proc/cmdline`、`/proc/mounts`；
- UBI 映射、网络、内核、模块和进程信息；
- `/etc`、`/usrdata` 文件系统快照；
- `/dev/mtd0` 的运行态 SBL。

运行态 SBL 是本次恢复的关键。EDL/Streaming 最初取得的 SBL 镜像为全 `0xff`，如果没有提前保存正常运行态 `mtd0-sbl.bin`，后续就缺少设备自身的可信恢复源。

### 4.2 Qualcomm EDL

EDL 适合保存：

- MIBIB 分区表；
- 15 个逻辑分区镜像；
- 完整 NAND 主数据视图；
- loader 与设备几何识别结果。

EDL 读取的是 ECC 校正后的主数据，不等于包含每页 OOB 的芯片级物理镜像。本次备份没有完整的 64 字节 OOB，也不能凭空还原原始坏块标记布局。

## 5. 操作时间线

### 5.1 停止主机服务

进入备份和 EDL 前，先停止 DJOneHub 与 DJOneHubNotifier，避免后台继续占用 USB AT、ADB、UAC 或 USB 网络接口。

经验：只退出前台窗口不够，LaunchAgent 仍可能自动重启服务。应同时确认 `launchctl print` 中服务已不存在或不再运行。

### 5.2 保存运行态元数据与文件系统

保存了：

- 内核、命令行和挂载状态；
- MTD/UBI 布局；
- ALSA PCM 列表；
- 网络、设备节点和内核模块信息；
- `/etc` 与 `/usrdata` tar 快照；
- 运行态 SBL。

对部分运行态 MTD 分区直接读取会让模块 NAND 路径全局卡死，因此没有强行用运行态 `dd` 读取所有分区，而是把主要分区读取转移到 EDL。

### 5.3 运行态 SBL 的安全传输

旧 ADB `shell:` 传输会把二进制中的换行做 CRLF 转换。直接执行类似下面的管道会破坏镜像：

```text
adb shell dd if=/dev/mtd0 | host-file
```

本次采用模块端 Base64 编码、Mac 端解码的方式传输，并验证：

- 解码后长度恰好为 1,310,720 字节；
- Base64 数据完整；
- SHA-256 固定。

如果 ADB 支持无终端转换的 `exec-out`，也应在使用前用已知二进制样本验证其是否真正透明。

### 5.4 进入 EDL 并识别设备

模块进入 EDL 后枚举为：

```text
05c6:9008 QHSUSB__BULK
```

通过 Sahara 读取并核对 SoC/HWID/PK hash，再选择匹配的 9x07 loader。身份值保存在私有日志，不写入公开仓库。

### 5.5 确认 NAND 几何与分区表

最终确认：

| 项目 | 数值 |
|---|---:|
| 页大小 | 2048 字节 |
| 页/块 | 64 |
| 擦除块 | 131072 字节 |
| 擦除块数 | 1024 |
| 主数据容量 | 134217728 字节 |
| SBL 块 | 0–9 |
| SBL 原始页 | 0–639 |

分区总长度正好覆盖 1024 个擦除块。

### 5.6 识别 256 MiB 容量假象

Streaming loader 一度报告 2048 个块，即 256 MiB。完整读取后发现：

- 前 128 MiB 与后 128 MiB SHA-256 相同；
- 两半逐字节一致；
- MIBIB 分区总长只有 128 MiB。

因此它是控制器地址回绕或 loader 容量识别问题，不是额外的物理 NAND。备份中保留了 256 MiB 控制器视图用于取证，但恢复时绝不能把它当作真实 256 MiB 整盘写回。

### 5.7 完成逻辑备份

最终保存：

- 15 个独立分区镜像；
- 128 MiB EDL 主数据镜像；
- 256 MiB 回绕控制器视图；
- 以运行态 SBL 覆盖 EDL SBL 区生成的 128 MiB 复合逻辑镜像；
- 文件系统快照与运行态元数据；
- 使用过的 loader；
- 覆盖所有文件的 `SHA256SUMS`。

每个独立分区都与整片 128 MiB 镜像对应偏移逐字节比较，复合镜像的 SBL 区也与运行态备份逐字节比较。

## 6. 固定 9008 的诊断过程

备份后模块持续枚举为 `05c6:9008`，无法回到 `2ca3:4006`。排查按“先排除临时状态，再考虑闪存内容”的顺序进行。

### 6.1 物理断电与等待

先后进行了普通重插和更长时间断电，目的是让 USB、PMIC、PS_HOLD 和 RAM 中的临时下载状态彻底消失。

所谓“等待 10 秒”不是 Qualcomm 规定的神奇时长，只是工程上的最低放电窗口：

- 让主机撤销旧 USB session；
- 让模块电源轨和电容下降；
- 避免快速重插仍保留上一次复位状态。

如果设备仍有旁路供电、大电容或 PMIC 保持，10 秒可能不够，所以后来使用了更长的断电时间。物理断电后仍固定 9008，说明问题不是单纯的 RAM/restart reason 残留。

### 6.2 检查 `misc` 与重启原因

检查了 `misc` 分区中的 recovery/EDL 标志，没有发现要求持续进入 recovery 或 EDL 的字符串/结构。

还检查并尝试恢复 Qualcomm 常见 restart reason，然后执行复位；设备仍回到 9008。

结论：固定 EDL 不是由已检查到的 `misc` 标志或临时 restart reason 单独造成。

### 6.3 检查硬复位路径

读取并操作 PS_HOLD 触发硬复位，设备立即重新枚举为 9008。再次说明 Boot ROM 启动后没有找到可继续执行的有效 SBL。

### 6.4 原始回读 SBL

使用能正确识别 NAND 几何的 Firehose programmer，从原始页 0 开始读取 640 页。结果：

- 长度：1,310,720 字节；
- 内容：擦除态；
- SHA-256：`35805909a516a528e396b6ea22dab437b6f1c703afe92e92dddfa0243bfae738`。

这一步把诊断从“可能是启动状态问题”推进为“启动介质上的 SBL 确实缺失”。

## 7. 失败路线与踩坑记录

### 7.1 读成功不代表写路径可用

精确匹配的 Streaming loader 能读取 NAND、分区表和大部分分区，但分区名写入还需要旧式用户分区表协议。

教训：

- loader 能上传，不等于它能初始化 NAND；
- 能读取 NAND，不等于它接受写入协议；
- 能打印分区，不等于能用 `w <partition>` 写同一分区。

### 7.2 新式物理表与旧式用户表不是同一种结构

QDC507 NAND 中的物理分区表使用一套带显式 offset/length 的格式；Streaming `0x19` 写入流程期待另一套旧式用户分区表。

直接提交或简单转换后，loader 返回：

```text
Unknown error accepting partition table
```

不能把旧格式简单理解为“现有长度 + 0 个保留块”。Quectel 示例表中，SBL 和 MIBIB 的主块/保留块拆分与总长度有关，但 QDC507 缺少可验证的原厂旧式表。凭猜测生成表可能改变坏块保留策略，风险超过只恢复 SBL 的授权范围。

最终没有采用 partition table override，也没有使用 `mode=1` 强制覆盖。

### 7.3 第一批 `edl w` 并没有真正写入

为了确认协议停在哪一步，临时给 EDL 工具增加了日志和写前 guard。记录显示：

1. security mode 返回 ACK；
2. partition table 返回拒绝；
3. guard 在 section header 前退出；
4. 没有发送镜像数据。

教训：判断“写命令是否执行”不能只看命令名称，必须确认协议阶段和原始 ACK。

### 7.4 进度条 100% 也可能是失败

一次绕过分区表、直接打开 `SBL` section 的实验中，loader 拒绝了 section header。工具的失败路径仍把进度条推进到 100%，随后才打印：

```text
Error on sending section header
Error on closing data stream
```

没有镜像数据被发送。

教训：进度条只是客户端 UI。必须同时检查 section header、每批 program ACK、close ACK、进程退出码和写后回读。

### 7.5 退出码 0 不一定代表目标操作完成

部分 `edl` 子命令在底层打印错误后仍以 0 退出，或者只完成 loader 初始化，没有完成目标 reset/read/write。

教训：自动化脚本不能只依赖 `$?`。至少还要匹配明确成功日志，并做外部状态验证，例如 USB VID:PID 变化或镜像哈希。

### 7.6 `nandprg`、Sahara 和 Firehose 模式会连续切换

同一个 USB `05c6:9008` 设备可能处于：

- Sahara，等待上传 programmer；
- 已运行旧式 `nandprg`/Streaming loader；
- 已运行 Firehose programmer。

命令行传入 `--loader` 不代表这次一定重新上传了该文件。如果设备已经运行 programmer，客户端可能直接连接现有模式。

一次 Streaming section 失败并关闭会话后，设备回到 Sahara；随后重新调用同一个 Quectel 文件，才真正上传并进入 Firehose。这成为最终突破。

教训：每次关键测试都要记录客户端打印的 `Mode detected`，必要时物理重插或明确 reset，使测试从已知模式开始。

### 7.7 不匹配的 NPRG/ENPRG 不能靠 SoC 名称硬用

尝试过多个 9x07 programmer。即使文件名和 SoC 系列相同，也可能因为 OEM 签名根、编译配置、NAND 驱动或目标内存布局不同而被拒绝、断开或卡住。

比较证书公钥后确认，不同 programmer 的根密钥并不相同。SoC 型号相同不是安全兼容性的充分条件。

### 7.8 Firehose 不认识 MIBIB 分区名

Quectel NAND Firehose 能识别实际 NAND 几何并支持 `read/program/erase`，但通用客户端的 GPT 分区解析不理解 QDC507 的 MIBIB，因此：

```text
edl r SBL ...
```

会报告找不到分区。

最终使用原始页命令，并根据已经验证的 MIBIB 几何计算页范围。原始页写入只适合边界已经多重确认的救援场景。

### 7.9 Firehose 默认 sector size 可能错误

客户端最初用 4096 或 512 字节探测，programmer 明确报告实际 NAND 页为 2048 字节，并产生 `STORAGE_READ_FAILURE`。

最终所有原始读写都显式指定：

```text
--memory=nand --sectorsize=2048 --pagesperblock=64
```

教训：不要让通用工具的 eMMC/UFS 默认值决定 NAND 页大小。

### 7.10 工作树源码不等于实际导入源码

EDL 工具在 Python venv 中运行，实际导入的是：

```text
<venv>/lib/pythonX.Y/site-packages/edlclient/...
```

修改临时 clone 下的同名文件不会影响正在运行的命令。

教训：修改诊断日志或 guard 后，应打印模块 `__file__` 或直接检查 venv site-packages，并运行 `py_compile`。

### 7.11 运行态读取 MTD 可能导致全局卡死

在正常 Linux 运行态读取 `mibib`、`efs2` 等原始 MTD 时，模块 NAND 路径可能卡住，后续读取也一起阻塞。

教训：

- 先保存最关键、最小的运行态资产，尤其是本机 SBL 和元数据；
- 不要为了“看起来更原始”而在挂载、运行中的 NAND 上连续扫全部 MTD；
- 大分区和 UBI 分区优先使用已验证的 EDL 只读路径。

### 7.12 ADB 文本通道会损坏二进制

旧 ADB shell 对 CR/LF 的转换不会报错，文件长度甚至可能只增加少量，看起来很像有效镜像。

教训：二进制传输后必须同时验证长度和哈希；不能只看命令返回成功。

### 7.13 重新插拔后不能只看 USB 设备名

恢复验证至少需要三层：

1. USB 从 `05c6:9008` 变为 `2ca3:4006`；
2. DJOneHub 能打开正确 USB AT interface/endpoints；
3. 实际 AT 查询返回 `OK`，后台 HTTP listener 和 Notifier 保持运行。

只看到 `Baiwang` 说明枚举恢复，不等于电话、短信和音频链路全部可用。

### 7.14 恢复后要重新加载 LaunchAgent

为了备份而卸载的服务不会因为模块恢复自动重新注册。恢复完成后重新 bootstrap DJOneHub 和 Notifier，并确认：

- state 为 running；
- PID 存在且没有退出码；
- USB 设备被 DJOneHub 独占；
- `127.0.0.1:7575` 处于 LISTEN；
- USB AT 查询成功。

### 7.15 HTTP 单次探测失败不能覆盖其他证据

一次 `curl` 在服务刚恢复时连接失败，但 `launchctl`、`lsof`、现有 ESTABLISHED 连接和后续短信日志都显示服务正常。

教训：诊断本地服务时应结合进程、监听套接字、连接和业务日志，不要让一次瞬时探测成为唯一结论。

### 7.16 备份报告本身也要进入校验清单

加入恢复 programmer 和更新报告后，旧 `SHA256SUMS` 已失效。本次重新生成清单并对全部文件执行 `shasum -a 256 -c`，结果全部为 `OK`。

## 8. 最终恢复路径

### 8.1 发现可工作的 Firehose

使用 Quectel 9x07 NAND Firehose programmer 后，设备返回：

```text
TargetName=9x07
MemoryName=NAND
total_blocks=1024
block_size=131072
page_size=2048
```

并声明支持：

```text
program configure power benchmark read getstorageinfo erase nop
```

这些值与 MIBIB、运行态 MTD 信息和 128 MiB 备份互相吻合。

### 8.2 写前原始回读

按原始页读取 SBL：

```text
start_sector = 0
sector_count = 640
sector_size = 2048
```

计算：

```text
640 × 2048 = 1,310,720 bytes
10 × 64 × 2048 = 1,310,720 bytes
```

读取结果与此前 EDL SBL 擦除态哈希一致，证明地址和长度没有偏移到 MIBIB。

### 8.3 原始页写入

最终写入只覆盖：

```text
page 0 ... page 639
offset 0x00000000 ... 0x0013ffff
```

来源为本机运行态 `mtd/mtd0-sbl.bin`。

没有额外执行整块 `erase`：写前目标页已经处于擦除态，Firehose `program` 对每批数据返回成功。这样避免引入一次不必要的独立擦除操作。

### 8.4 写后回读验证

在复位前重新读取同一 640 页到新文件，并验证：

- 源文件长度：1,310,720 字节；
- 回读文件长度：1,310,720 字节；
- 两者 SHA-256 相同；
- `cmp` 逐字节比较返回一致。

源与回读 SHA-256：

```text
42251657c4d75ce0020e39a8205bafdedfb36de467823bd0c99c86b85e8e5496
```

只有完成这一步后才发送 Firehose reset。

### 8.5 启动与业务验证

复位后：

- USB 恢复为 `2ca3:4006 Baiwang`；
- DJOneHub 打开 USB AT interface 2，OUT `0x03`、IN `0x84`；
- `AT+QCFG="USBCFG"?` 返回当前组合配置和 `OK`；
- Web 服务监听 `127.0.0.1:7575`；
- Notifier 与主服务保持运行；
- 后续成功接收并重组三段短信，证明 AT 业务通道恢复。

`AT+QPCMV?` 和 `AT+QDAI?` 返回 `ERROR` 是该固件原有的不支持查询行为，不应单独判定为本次 SBL 恢复失败。

## 9. 命令模板

以下命令只用于解释本次流程，不是通用刷机指令。任何写入前都必须替换路径、核对同一设备备份，并再次确认几何和范围。

### 9.1 查看 USB 模式

```bash
ioreg -p IOUSB -l -w 0 | rg -i -C 3 'QHSUSB|Baiwang|idProduct|idVendor'
```

### 9.2 Firehose 原始读取 SBL

```bash
edl rs 0 640 sbl-readback.bin \
  --loader=prog_nand_firehose_9x07.mbn \
  --memory=nand \
  --sectorsize=2048 \
  --pagesperblock=64 \
  --vid=0x05c6 \
  --pid=0x9008
```

### 9.3 校验写入来源

```bash
wc -c mtd0-sbl.bin
shasum -a 256 mtd0-sbl.bin
```

预期长度必须由目标设备自己的分区表推导，不能照抄本报告。

### 9.4 本次使用的原始页写入形式

```bash
edl ws 0 mtd0-sbl.bin \
  --loader=prog_nand_firehose_9x07.mbn \
  --memory=nand \
  --sectorsize=2048 \
  --pagesperblock=64 \
  --vid=0x05c6 \
  --pid=0x9008
```

这是不可逆的高风险命令。只有“同一设备 SBL、目标页已核对、用户明确授权、完整备份已校验”同时成立时才可考虑执行。

### 9.5 写后独立回读

```bash
edl rs 0 640 sbl-after.bin \
  --loader=prog_nand_firehose_9x07.mbn \
  --memory=nand \
  --sectorsize=2048 \
  --pagesperblock=64 \
  --vid=0x05c6 \
  --pid=0x9008

shasum -a 256 mtd0-sbl.bin sbl-after.bin
cmp -s mtd0-sbl.bin sbl-after.bin
```

### 9.6 全备份校验

```bash
shasum -a 256 -c SHA256SUMS
```

## 10. 关键资产与哈希

私有备份内的重要文件：

| 文件 | 用途 | SHA-256 |
|---|---|---|
| `mtd/mtd0-sbl.bin` | 同一设备运行态权威 SBL | `42251657c4d75ce0020e39a8205bafdedfb36de467823bd0c99c86b85e8e5496` |
| `edl-tools/prog_nand_firehose_9x07.mbn` | 最终成功的 NAND Firehose programmer | `2e32df166a2d67facf500db19e1b741d11d1f183aa8decb2c944319da88a41b6` |
| `edl-tools/000480e1…_enprg_peek.bin` | 匹配设备的 Streaming/peek loader | `8cd89982f77721021572d05aad0d9b1c5e822e8c8f4828abc5aaeb23fa4f5fcd` |
| `edl-partitions/partition.bin` | 原始 MIBIB 分区表页 | `27ed6b1287ad7e6677ce0850b4e57476cbacc2f07a28b4009586d6909e04583f` |

完整文件名中的设备身份部分在公开文档中省略。以私有 `SHA256SUMS` 为最终准绳。

## 11. 推荐的下一次备份流程

如果以后再备份同类模块，推荐按下面顺序，减少进入不可启动状态后的不确定性。

### 阶段 A：正常模式

1. 停止会占用 USB 的后台服务。
2. 保存 USB 描述符、AT 配置和模块状态。
3. 保存 `/proc/mtd`、UBI、mount、cmdline、内核和 ALSA 信息。
4. 第一优先级保存本机运行态 SBL，并立即验证长度、哈希和二进制透明性。
5. 保存 `/etc`、`/usrdata` 和设备配置清单。
6. 在任何 EDL 操作前复制一份只读工作备份。

### 阶段 B：EDL 只读

1. 记录 Sahara 身份，但不把敏感值写入公开文档。
2. 只加载已验证匹配的 programmer。
3. 先读取 NAND geometry 和分区表。
4. 先读小范围并与运行态信息交叉验证。
5. 再读取所有独立分区和整片主数据。
6. 检查容量回绕、坏块提示和异常全 `0xff` 区域。
7. 不在备份阶段测试写命令、partition override 或 erase。

### 阶段 C：验证与封存

1. 检查每个分区长度。
2. 比较独立分区与整片镜像对应范围。
3. 识别 UBI、Android boot image、ELF 等文件类型。
4. 生成 SHA-256 清单。
5. 将目录设为 `0700`，文件设为 `0600`。
6. 至少保存两份物理位置独立的副本。

### 阶段 D：退出 EDL

1. 先发送明确 reset。
2. 观察 USB 是否回到正常 VID:PID。
3. 如果仍为 9008，先只读确认 SBL，不要连续尝试不同写法。
4. 物理断电用于排除临时状态，但不能修复闪存中已擦除的 SBL。
5. 恢复主机 LaunchAgent 并验证 AT、HTTP、短信和通话相关状态。

## 12. 改进建议

### 12.1 为备份工具加入只读模式

备份脚本应默认拒绝所有 `w/wl/ws/wf/e/es` 命令，只有单独的恢复工具才允许写入。这样可以把“备份”和“救援”权限分离。

### 12.2 记录每次模式切换

每条命令前后记录：

- USB VID:PID；
- Sahara/nandprg/Firehose mode；
- loader 文件 SHA-256；
- NAND geometry；
- 命令开始和结束时间；
- 原始 ACK 或明确成功文本。

这能减少“以为加载了 A，实际仍在运行 B”的问题。

### 12.3 在任何写入前自动执行边界证明

恢复工具应自动拒绝以下情况：

- 镜像为空或长度超出目标；
- 目标 offset/length 与备份表不一致；
- live geometry 与报告不一致；
- loader 哈希不在允许列表；
- 没有写前回读；
- 没有明确的设备本地授权记录。

### 12.4 把写后回读作为成功条件

“program 返回 ACK”只能证明 programmer 接收了命令。恢复成功的判定应是：

```text
program ACK
AND readback length matches
AND SHA-256 matches
AND byte comparison matches
AND device boots normally
```

### 12.5 保留公开报告与私有报告的边界

公开仓库只保存架构、方法、几何和脱敏哈希。私有备份报告可以记录本地路径、完整 loader 名称和设备身份，但不应上传 EFS、usr_data、完整镜像、SIM/eSIM 信息或日志原文。

## 13. 经验总结

这次恢复最重要的经验不是“找到一个能刷的 loader”，而是建立了证据链：

1. 正常运行态提前保存了同一设备 SBL。
2. MIBIB、MTD 和 Firehose 对 NAND 几何给出一致结果。
3. 写前原始回读证明目标 SBL 确实为空。
4. 写入范围严格等于 SBL 分区，没有触碰 MIBIB。
5. 写后原始回读与来源逐字节一致。
6. 复位后 USB、AT、后台服务和实际短信业务共同证明启动恢复。

反过来，最危险的做法是：看到 9008 后连续换 loader、猜分区表、使用 override、只看进度条，或者在没有本机 SBL 的情况下写入网上找到的同型号镜像。

救援工作的核心不是“多试几个命令”，而是让每一步都缩小不确定性，并确保失败不会扩大已授权的写入范围。

## 14. 相关文档

- [iOS 模块侧电话网关设计](ios-module-gateway-design.md)
- 私有备份中的 `BACKUP_REPORT.md`
- 私有备份中的 `SHA256SUMS`

