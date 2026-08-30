import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var probe: AudioProbeModel
    @EnvironmentObject private var networkProbe: ModuleNetworkProbe
    @EnvironmentObject private var voiceControl: VoiceControlModel

    var body: some View {
        NavigationStack {
            List {
                statusSection
                networkSection
                voiceControlSection
                routeSection
                controlsSection
                logSection
            }
            .navigationTitle("DJOneHub UAC Probe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") {
                        probe.refresh(reason: "manual refresh")
                    }
                }
            }
        }
    }

    private var voiceControlSection: some View {
        Section("模块电话控制（实验）") {
            LabeledContent("认证状态", value: voiceControl.stateText)

            Button(voiceControl.isBusy ? "读取中…" : "读取模块通话状态") {
                voiceControl.refreshStatus()
            }
            .disabled(voiceControl.isBusy || !voiceControl.isConfigured)

            if !voiceControl.detailText.isEmpty {
                Text(voiceControl.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("当前只接入只读 STATUS。pairing key 必须由尚未实现的生产配对流程在内存中注入；App 不生成、不持久化，也不在界面中要求粘贴真实密钥。未完成配对前，按钮保持禁用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section("ECM 网络探针") {
            LabeledContent("有线网络路径", value: networkProbe.pathText)
            LabeledContent("模块地址", value: "\(networkProbe.host):\(networkProbe.port)")
            LabeledContent("控制端口", value: networkProbe.stateText)
            LabeledContent("往返时间", value: networkProbe.latencyText)

            Button(networkProbe.isTesting ? "探测中…" : "测试模块控制端口") {
                networkProbe.probeControlPort()
            }
            .disabled(networkProbe.isTesting)

            if !networkProbe.detailText.isEmpty {
                Text(networkProbe.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("只探测 TCP 控制面，不发送拨号、PCM 或其他通话命令。ECM 已能上网但端口拒绝时，表示网络链路正常，模块侧 djonehubd 尚未监听。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section("判定") {
            Label(probe.verdict, systemImage: probe.isUsefulProbeRoute ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(probe.isUsefulProbeRoute ? .green : .orange)

            LabeledContent("Audio Session", value: probe.isSessionActive ? "已激活" : "未激活")
            LabeledContent("路由状态", value: probe.isRouteStable ? "稳定" : "切换中")
            LabeledContent("输入电平", value: probe.meterText)

            ProgressView(value: probe.inputLevel)
                .tint(probe.isUSBInput ? .green : .orange)
        }
    }

    private var routeSection: some View {
        Section("当前路由") {
            routeBlock(title: "输入", routes: probe.currentInputs)
            routeBlock(title: "输出", routes: probe.currentOutputs)

            DisclosureGroup("可选输入（\(probe.availableInputs.count)）") {
                routeBlock(title: "availableInputs", routes: probe.availableInputs)
            }

            LabeledContent("采样率", value: probe.sampleRateText)
            LabeledContent("I/O Buffer", value: probe.ioBufferText)
            LabeledContent("输入可用", value: probe.inputAvailable ? "是" : "否")
        }
    }

    private func routeBlock(title: String, routes: [AudioRouteItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if routes.isEmpty {
                Text("无")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(routes) { route in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name)
                            .font(.body.weight(.medium))
                        Text("\(route.type) · \(route.channelCount) ch")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(route.uid)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var controlsSection: some View {
        Section("验证") {
            Button("下行模式：选择模块 USB 输入") {
                probe.activateAndPreferUSB()
            }

            Button("上行模式：选择 iPhone 内置麦克风") {
                probe.activateAndPreferBuiltInMic()
            }

            Button("下行扬声器模式：USB 输入 + iPhone 扬声器") {
                probe.activateUSBInputAndSpeaker()
            }

            Button(probe.isMetering ? "停止输入电平" : "启动输入电平") {
                probe.toggleMeter()
            }
            .disabled(!probe.isSessionActive || !probe.isRouteStable)

            Button("播放 0.5 秒安全测试音") {
                probe.playTestTone()
            }
            .disabled(!probe.isSessionActive || !probe.isRouteStable || !probe.isUSBOutput)

            Button(probe.isForwardingUplink ? "停止麦克风上行" : "内置麦克风送往 USB 输出") {
                probe.toggleUplinkForwarding()
            }
            .disabled(!probe.isSessionActive || !probe.isRouteStable || !probe.isBuiltInMicInput || !probe.isUSBOutput)

            Button(probe.isForwardingDownlink ? "停止扬声器下行" : "模块 USB 输入送往 iPhone 扬声器") {
                probe.toggleDownlinkForwarding()
            }
            .disabled(!probe.isSessionActive || !probe.isRouteStable || !probe.isUSBInput || !probe.isBuiltInSpeakerOutput)

            Text("测试音为 700 Hz、峰值约 -24 dBFS，并且只有当前输出为 USB Audio 时才能播放。“麦克风上行”只有系统实际采用内置麦克风 + USB 输出时才能启动；“扬声器下行”用于验证 iOS 是否允许 USB 输入与内置扬声器并行。切换模式会等待路由稳定并重建音频引擎，避免误把模块下行回送给对端。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        Section("事件日志") {
            Text(probe.logText.isEmpty ? "暂无事件" : probe.logText)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            ShareLink(item: probe.logText, subject: Text("DJOneHub UAC Probe 日志")) {
                Label("导出日志", systemImage: "square.and.arrow.up")
            }
            .disabled(probe.logText.isEmpty)

            Button("清空日志", role: .destructive) {
                probe.clearLog()
            }
            .disabled(probe.logText.isEmpty)
        }
    }
}
