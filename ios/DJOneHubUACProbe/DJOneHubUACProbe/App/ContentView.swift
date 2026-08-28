import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var probe: AudioProbeModel

    var body: some View {
        NavigationStack {
            List {
                statusSection
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

    private var statusSection: some View {
        Section("判定") {
            Label(probe.verdict, systemImage: probe.isBidirectionalUSB ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(probe.isBidirectionalUSB ? .green : .orange)

            LabeledContent("Audio Session", value: probe.isSessionActive ? "已激活" : "未激活")
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

            Button(probe.isMetering ? "停止输入电平" : "启动输入电平") {
                probe.toggleMeter()
            }
            .disabled(!probe.isSessionActive)

            Button("播放 0.5 秒安全测试音") {
                probe.playTestTone()
            }
            .disabled(!probe.isSessionActive || !probe.isUSBOutput)

            Button(probe.isForwardingUplink ? "停止麦克风上行" : "内置麦克风送往 USB 输出") {
                probe.toggleUplinkForwarding()
            }
            .disabled(!probe.isSessionActive || !probe.isBuiltInMicInput || !probe.isUSBOutput)

            Text("测试音为 700 Hz、峰值约 -24 dBFS，并且只有当前输出为 USB Audio 时才能播放。“麦克风上行”只有系统实际采用内置麦克风 + USB 输出时才能启动，声音会直接送给通话对端。切换模式会先停止音频引擎，避免误把模块下行回送给对端。")
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
