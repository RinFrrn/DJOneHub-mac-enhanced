# iOS 通话音频设备切换计划

日期：2026-09-11。状态：待实施；本文记录计划，不代表功能已完成或经过真机验收。

## 目标与范围

来电和拨出电话共用音频设备切换能力，支持 iPhone 听筒、扬声器，以及系统提供的蓝牙通话耳机。保持现有模块 ECM 双向 PCM 链路，兼容最低 iOS 17。

与[模块连接提速计划](ios-module-connection-speed-plan.md)衔接：先完成连接耗时测量和 App 连接调度优化，再统一调整音频初始化、设备切换和恢复逻辑。

## 已确认的现状

- [CallAudioCoordinator.swift](../ios/DJOneHubUACProbe/DJOneHubUACProbe/Audio/CallAudioCoordinator.swift) 的 `currentRouteMatchesPolicy` 只接受内置麦克风和扬声器。
- `configureCallAudioSession` 设置 `.defaultToSpeaker`，`activateBuiltInCallRoute` 强制选择内置麦克风和 `.speaker`；路由恢复也会再次执行此策略。
- [InCallView.swift](../ios/DJOneHubUACProbe/AirPhone/InCallView.swift) 没有音频设备切换入口。
- `pauseForRouteRecovery` 会停止录音并拆除媒体资源，因此不能只增加一个切换按钮。
- [SystemCallCoordinator.swift](../ios/DJOneHubUACProbe/AirPhone/SystemCallCoordinator.swift) 已通过 CallKit 激活、停用回调协调媒体生命周期，需要保留该所有权边界。

## 用户体验

- 通话页增加“音频”按钮，显示实际使用的听筒、扬声器或耳机名称。
- 点击展开可用设备列表，当前设备打勾；切换中显示进度，失败后显示原因和实际设备。
- 默认尊重系统选择；没有耳机时使用听筒。没有听筒的设备根据实际能力提供选项。
- 耳机断开后，iPhone 回退听筒，避免突然外放；无听筒设备另行明确回退策略并验收。
- 未接听时不提前启动麦克风；接听且音频会话激活后允许切换。
- 系统锁屏通话页与 App 内的设备显示保持一致。

## 实施步骤

### 1. 建立路由状态模型

- [ ] 分别建模用户请求、系统实际路由、可用设备及切换状态。
- [ ] 使用设备标识区分多个同名耳机，显示名称用于 UI。
- [ ] 将路由决策集中在音频协调层；UI 只提交选择并展示状态。

### 2. 解除固定扬声器策略

- [ ] 移除固定默认外放，按用户选择设置听筒、扬声器或耳机。
- [ ] 启用支持双向通话的蓝牙 HFP 输入，按系统版本使用兼容 API。
- [ ] 从系统可用设备中选择输入，以 `currentRoute` 确认实际输入和输出；API 返回成功不等于设备已切换完成。
- [ ] 保留对 QDC507 USB Audio 端口的处理，避免声音误送回模块。
- [ ] 在真机确认插着模块时听筒、扬声器、蓝牙均能形成目标输入输出组合。

### 3. 改造切换与恢复

- [ ] 合并连续路由变化通知，用请求代次取消过期切换和恢复任务。
- [ ] 按实际硬件采样率、声道和引擎配置重建必要资源；模块传输保持 8 kHz PCM。
- [ ] 保留静音状态，处理录音连续性；不能在切换时静默结束录音，无法继续时须明确反馈。
- [ ] 处理耳机接入、断开、中断恢复、后台返回和音频服务重置。
- [ ] 切换失败回到可用路由并更新 UI，避免无限重试或来回跳转。

### 4. 接入通话 UI 与 CallKit

- [ ] 为来电接听后和拨出通话接入同一个音频选择入口。
- [ ] CallKit 管理会话时等待系统激活，不主动争夺会话激活权。
- [ ] 接收系统通话页的路由变化，更新 App 状态，不强制切回原设备。
- [ ] 检查小屏、大字体、VoiceOver、设备名称过长和设备列表动态变化。

### 5. 验证与交付

- [ ] 自动测试覆盖路由决策、设备断开、连续切换、过期恢复任务、失败回退和静音状态保留。
- [ ] 运行相关既有音频恢复测试及 AirPhone 主应用 Debug、Release 构建。
- [ ] 真机测试听筒 ↔ 扬声器 ↔ AirPods／普通蓝牙通话耳机，分别验证双方声音。
- [ ] 真机覆盖来电、拨出、静音、录音、锁屏切换、耳机断连和模块插拔。

验收要求：设备显示准确、切换后双方持续可听、不自行跳回扬声器、耳机断开不意外外放，录音状态与实际保存结果一致。切换短暂音频间隙需实测记录，不能仅凭构建成功宣称无缝切换。

分两步交付：先打通听筒／扬声器和系统界面同步，再完成蓝牙及异常恢复验收。

## Apple 参考资料

- [蓝牙 HFP 会话选项](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp)
- [选择音频输入与确认实际路由](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:))
- [扬声器覆盖与默认外放的区别](https://developer.apple.com/library/archive/qa/qa1754/_index.html)
- [响应音频路由变化](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
