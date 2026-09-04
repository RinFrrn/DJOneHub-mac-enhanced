import SwiftUI

struct InCallView: View {
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var callAudio: CallAudioCoordinator
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator

    let onAnswer: (UInt8) -> Void
    let onEnd: (UInt8) -> Void
    let onToggleMute: () -> Void
    let onToggleRecording: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.12, blue: 0.18), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 44)
                Text(callTitle)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(statusText)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(callAudio.isRecording ? .red : .white.opacity(0.68))

                Circle()
                    .fill(.white.opacity(0.13))
                    .frame(width: 120, height: 120)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                if case .incoming(let callID) = lifecycle.phase {
                    Spacer()
                    HStack(spacing: 76) {
                        CallActionButton(title: "拒绝", systemImage: "phone.down.fill", color: .red) {
                            onEnd(callID)
                        }
                        CallActionButton(title: "接听", systemImage: "phone.fill", color: .green) {
                            onAnswer(callID)
                        }
                    }
                } else {
                    Spacer()
                    HStack(spacing: 34) {
                        CallActionButton(
                            title: "静音",
                            systemImage: lifecycle.isMuted ? "mic.slash.fill" : "mic.fill",
                            color: lifecycle.isMuted ? .white : .white.opacity(0.18),
                            foreground: lifecycle.isMuted ? .black : .white,
                            action: onToggleMute
                        )
                        .disabled(!isActive)
                        .opacity(isActive ? 1 : 0.45)

                        CallActionButton(
                            title: callAudio.isRecording ? "停止录音" : "录音",
                            systemImage: callAudio.isRecording ? "stop.fill" : "record.circle",
                            color: callAudio.isRecording ? .red : .white.opacity(0.18),
                            action: onToggleRecording
                        )
                        .disabled(!isActive)
                        .opacity(isActive ? 1 : 0.45)
                    }

                    if !callAudio.recordingErrorText.isEmpty {
                        Text(callAudio.recordingErrorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if let callID = lifecycle.phase.callID {
                        CallActionButton(title: "挂断", systemImage: "phone.down.fill", color: .red) {
                            onEnd(callID)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                Spacer(minLength: 30)
            }
            .padding(.horizontal, 28)
        }
    }

    private var isActive: Bool {
        if case .active = lifecycle.phase { return true }
        return false
    }

    private var callTitle: String {
        let number = voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .incoming = lifecycle.phase { return "未知号码" }
        return number.isEmpty ? "蜂窝电话" : number
    }

    private var statusText: String {
        if callAudio.isRecording {
            return "● 录音中  \(phoneDurationText(TimeInterval(callAudio.recordingElapsedSeconds)))"
        }
        switch lifecycle.phase {
        case .placingCall: return "正在拨号…"
        case .dialing: return "正在呼叫…"
        case .incoming: return "来电"
        case .answering: return "正在接听…"
        case .active: return phoneDurationText(TimeInterval(lifecycle.activeCallDurationSeconds))
        case .ending: return "正在挂断…"
        default: return lifecycle.phase.title
        }
    }
}

private struct CallActionButton: View {
    let title: String
    let systemImage: String
    let color: Color
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 68, height: 68)
                    .foregroundStyle(foreground)
                    .background(color, in: Circle())
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(PhoneCircleButtonStyle())
    }
}

struct SettingsView: View {
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var callAudio: CallAudioCoordinator
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @Binding var isConfirmingUnpair: Bool
    let dismiss: () -> Void

    @State private var recordings: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section("模块") {
                    Label(lifecycle.phase.title, systemImage: lifecycle.phase.systemImage)
                    if let identifier = voiceControl.moduleIdentifier {
                        LabeledContent("模块", value: String(identifier.prefix(8)))
                    }
                    if !voiceControl.detailText.isEmpty {
                        Text(voiceControl.detailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(voiceControl.isConfigured ? "替换模块配对" : "导入模块配对") {
                        voiceControl.isImportingPairing = true
                    }
                    if voiceControl.isConfigured {
                        Button("删除 iPhone 本机配对", role: .destructive) {
                            isConfirmingUnpair = true
                        }
                    }
                }

                Section("通话录音") {
                    if recordings.isEmpty {
                        Text("暂无录音").foregroundStyle(.secondary)
                    } else {
                        ForEach(recordings, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(recordingTitle(url), systemImage: "waveform")
                            }
                        }
                    }
                    Text("录音为 8 kHz、16-bit、双声道 WAV：左声道是本机麦克风，右声道是对端语音。文件仅保存在本机且不进入 iCloud 备份。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("诊断") {
                    LabeledContent("PCM", value: callAudio.stateText)
                    LabeledContent("上行", value: "\(callAudio.sentFrames) 帧")
                    LabeledContent("下行", value: "\(callAudio.receivedFrames) 帧")
                    LabeledContent("媒体恢复", value: "\(callAudio.recoveryGeneration) 次")
                    LabeledContent(
                        "链路",
                        value: "丢包 \(callAudio.downlinkMetrics.concealedFrames) · 乱序 \(callAudio.downlinkMetrics.reorderedPackets)"
                    )
                    LabeledContent(
                        "播放",
                        value: "重缓冲 \(callAudio.downlinkMetrics.rebufferEvents) · 丢弃 \(callAudio.downlinkMetrics.queueDroppedFrames)"
                    )
                }

                Section {
                    Text("当前版本通过 USB ECM 控制 QDC507 并传输电话 PCM，不使用 USB Audio，也尚未接入 CallKit。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置与诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: dismiss)
                }
            }
            .onAppear { reloadRecordings() }
            .onChange(of: callAudio.lastRecordingURL) { _, _ in reloadRecordings() }
        }
    }

    private func reloadRecordings() {
        recordings = CallRecordingController.recordings()
    }

    private func recordingTitle(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "DJOneHub-", with: "")
    }
}
