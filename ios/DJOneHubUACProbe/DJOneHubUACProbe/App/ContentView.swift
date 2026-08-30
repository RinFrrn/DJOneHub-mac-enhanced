import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var probe: AudioProbeModel
    @EnvironmentObject private var networkProbe: ModuleNetworkProbe
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @State private var isConfirmingDial = false

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
        .fileImporter(
            isPresented: $voiceControl.isImportingPairing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importPairing(result)
        }
        .confirmationDialog(
            "撤销当前模块的测试配对？",
            isPresented: $voiceControl.isConfirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("撤销配对", role: .destructive) {
                voiceControl.unpairCurrentModule()
            }
        }
        .task(id: voiceControl.moduleIdentifier) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if voiceControl.canControlCalls && voiceControl.shouldPollStatus {
                    voiceControl.pollStatus()
                }
            }
        }
        .confirmationDialog(
            "确认拨打 \(voiceControl.dialNumber)？",
            isPresented: $isConfirmingDial,
            titleVisibility: .visible
        ) {
            Button("拨打") {
                voiceControl.dial()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var voiceControlSection: some View {
        Section("模块电话控制（实验）") {
            LabeledContent("认证状态", value: voiceControl.stateText)

            if voiceControl.availableModuleIdentifiers.count > 1 {
                Picker("模块", selection: Binding(
                    get: { voiceControl.moduleIdentifier ?? "" },
                    set: { voiceControl.selectPairing(moduleIdentifier: $0) }
                )) {
                    Text("请选择").tag("")
                    ForEach(voiceControl.availableModuleIdentifiers, id: \.self) { identifier in
                        Text(String(identifier.prefix(8))).tag(identifier)
                    }
                }
            }

            Button("导入测试配对包") {
                voiceControl.isImportingPairing = true
            }

            Button(voiceControl.isBusy ? "读取中…" : "读取模块通话状态") {
                voiceControl.refreshStatus()
            }
            .disabled(voiceControl.isBusy || !voiceControl.isConfigured)

            if voiceControl.canControlCalls {
                TextField("电话号码", text: $voiceControl.dialNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)

                Button("拨打电话") {
                    isConfirmingDial = true
                }
                .disabled(
                    voiceControl.isBusy ||
                    voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            ForEach(voiceControl.calls, id: \.id) { call in
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("通话 #\(call.id)", value: callStateName(call.state))
                    HStack {
                        if voiceControl.canControlCalls && [UInt8(0x02), 0x07].contains(call.state) {
                            Button("接听") {
                                voiceControl.answer(callID: call.id)
                            }
                            .disabled(voiceControl.isBusy)
                        }
                        if voiceControl.canControlCalls && call.state != 0x09 {
                            Button("挂断", role: .destructive) {
                                voiceControl.end(callID: call.id)
                            }
                            .disabled(voiceControl.isBusy)
                        }
                    }
                }
            }

            if voiceControl.isConfigured {
                Button("撤销当前测试配对", role: .destructive) {
                    voiceControl.isConfirmingUnpair = true
                }
            }

            if !voiceControl.detailText.isEmpty {
                Text(voiceControl.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(voiceControl.canControlCalls
                 ? "当前是一次启动有效的开发控制会话，可执行拨号、接听和挂断。模块断电后会话失效；测试凭据只保存在本机不可同步 Keychain。这仍不是最终的无 Mac 生产配对方案。"
                 : "STATUS 配对仅允许只读状态。测试配对包由 Mac 武装流程生成，显式导入后只保存到本机不可同步 Keychain；请随即删除原文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func callStateName(_ state: UInt8) -> String {
        switch state {
        case 0x01: return "拨号中"
        case 0x02: return "来电"
        case 0x03: return "通话中"
        case 0x04: return "呼叫进展"
        case 0x05: return "振铃"
        case 0x07: return "等待"
        case 0x09: return "结束"
        default: return "状态 0x\(String(state, radix: 16))"
        }
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            voiceControl.importDevelopmentPairingBundle(try Data(contentsOf: url))
        } catch {
            voiceControl.reportPairingImportFailure(error)
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
            .disabled(networkProbe.isTesting || voiceControl.isConfigured)

            if !networkProbe.detailText.isEmpty {
                Text(networkProbe.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(voiceControl.isConfigured
                 ? "已有测试配对时请使用认证 STATUS；裸 TCP 探针已禁用，避免旧版 one-shot daemon 被提前消费。"
                 : "只探测 TCP 控制面，不发送拨号、PCM 或其他通话命令。ECM 已能上网但端口拒绝时，表示网络链路正常，模块侧 djonehubd 尚未监听。")
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
            .disabled(!probe.isDownlinkRouteAvailable)

            if !probe.isForwardingDownlink {
                Text(probe.downlinkAvailabilityText)
                    .font(.footnote)
                    .foregroundStyle(probe.isDownlinkRouteAvailable ? .green : .secondary)
            }

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
