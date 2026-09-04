import SwiftUI
import UniformTypeIdentifiers

struct DJOneHubRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var callAudio: CallAudioCoordinator
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator

    @State private var isConfirmingDial = false
    @State private var isConfirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                callSection
                audioSection
                pairingSection
            }
            .navigationTitle("DJOneHub")
        }
        .task {
            lifecycle.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                lifecycle.applicationDidBecomeActive()
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
            "确认拨打 \(voiceControl.dialNumber)？",
            isPresented: $isConfirmingDial,
            titleVisibility: .visible
        ) {
            Button("拨打") {
                lifecycle.dial()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除 iPhone 本机配对？模块侧开发凭据仍会保留，需接回 Mac 后卸载。",
            isPresented: $isConfirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("仅删除本机配对", role: .destructive) {
                voiceControl.unpairCurrentModule()
                lifecycle.pairingDidChange()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var connectionSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lifecycle.phase.title)
                        .font(.headline)
                    if let identifier = voiceControl.moduleIdentifier {
                        Text("模块 \(identifier.prefix(8))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: lifecycle.phase.systemImage)
                    .foregroundStyle(phaseColor)
            }

            if case .recovering(let reason) = lifecycle.phase, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !voiceControl.detailText.isEmpty {
                Text(voiceControl.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("连接")
        }
    }

    @ViewBuilder
    private var callSection: some View {
        Section("电话") {
            switch lifecycle.phase {
            case .needsPairing, .needsControlPairing:
                Button("添加模块配对") {
                    voiceControl.isImportingPairing = true
                }

            case .connecting, .recovering:
                HStack {
                    ProgressView()
                    Text("正在等待 USB ECM 和模块服务")
                        .foregroundStyle(.secondary)
                }

            case .placingCall:
                HStack {
                    ProgressView()
                    Text("正在向模块发送拨号请求")
                        .foregroundStyle(.secondary)
                }

            case .ready:
                TextField("电话号码", text: $voiceControl.dialNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                Button("拨打电话", systemImage: "phone.fill") {
                    isConfirmingDial = true
                }
                .disabled(trimmedDialNumber.isEmpty || voiceControl.isBusy)

            case .dialing(let callID):
                callStatus(title: "正在呼叫", callID: callID)
                Button("取消呼叫", role: .destructive) {
                    lifecycle.end(callID: callID)
                }
                .disabled(voiceControl.isBusy)

            case .incoming(let callID):
                callStatus(title: "模块来电", callID: callID)
                HStack {
                    Button("拒接", role: .destructive) {
                        lifecycle.end(callID: callID)
                    }
                    .disabled(voiceControl.isBusy)
                    Spacer()
                    Button("接听") {
                        lifecycle.answer(callID: callID)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(voiceControl.isBusy)
                }

            case .answering(let callID):
                callStatus(title: "正在接听", callID: callID)
                ProgressView()

            case .active(let callID):
                callStatus(title: "通话中", callID: callID)
                Button("挂断", role: .destructive) {
                    lifecycle.end(callID: callID)
                }
                .disabled(voiceControl.isBusy)

            case .ending:
                HStack {
                    ProgressView()
                    Text("正在结束通话")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var audioSection: some View {
        Section("通话音频") {
            LabeledContent("PCM", value: callAudio.stateText)
            if !callAudio.detailText.isEmpty {
                Text(callAudio.detailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("上行", value: "\(callAudio.sentFrames) 帧")
            LabeledContent("下行", value: "\(callAudio.receivedFrames) 帧")
            LabeledContent("本地回铃", value: callAudio.isLocalRingbackEnabled ? "待命" : "关闭")
            LabeledContent(
                "链路修复",
                value: "丢包 \(callAudio.downlinkMetrics.concealedFrames) · 乱序 \(callAudio.downlinkMetrics.reorderedPackets)"
            )
            LabeledContent(
                "播放恢复",
                value: "重缓冲 \(callAudio.downlinkMetrics.rebufferEvents) · 队列丢弃 \(callAudio.downlinkMetrics.queueDroppedFrames)"
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("麦克风")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: callAudio.inputLevel)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("对端语音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: callAudio.downlinkLevel)
            }

            Text("拨号时立即播放回铃音和运营商提示，进入通话后才放行内置麦克风；媒体通过 USB ECM，不经过 USB Audio。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        Section("模块") {
            Button(voiceControl.isConfigured ? "替换模块配对" : "导入模块配对") {
                voiceControl.isImportingPairing = true
            }
            if voiceControl.isConfigured {
                Button("删除 iPhone 本机配对", role: .destructive) {
                    isConfirmingUnpair = true
                }
            }
            Text("当前版本是前台通话 MVP，尚未接入 CallKit。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedDialNumber: String {
        voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var phaseColor: Color {
        switch lifecycle.phase {
        case .ready, .active: return .green
        case .incoming: return .blue
        case .placingCall, .dialing, .answering, .ending, .connecting, .recovering: return .orange
        case .needsPairing, .needsControlPairing: return .secondary
        }
    }

    private func callStatus(title: String, callID: UInt8) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text("通话 #\(callID)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            voiceControl.importDevelopmentPairingBundle(try Data(contentsOf: url))
            lifecycle.pairingDidChange()
        } catch {
            voiceControl.reportPairingImportFailure(error)
        }
    }
}
