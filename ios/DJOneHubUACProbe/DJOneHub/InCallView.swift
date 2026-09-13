import AVFAudio
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
        CallScreenLayout(
            callTitle: callTitle, statusText: statusText,
            isRecording: callAudio.isRecording, isMuted: lifecycle.isMuted,
            isActive: isActive, incomingCallID: incomingCallID,
            callID: lifecycle.phase.callID, canSelectAudioRoute: callAudio.canSelectAudioRoute,
            recordingErrorText: callAudio.recordingErrorText, audioRouteErrorText: callAudio.audioRouteErrorText,
            onAnswer: onAnswer, onEnd: onEnd, onToggleMute: onToggleMute,
            onToggleRecording: onToggleRecording
        ) {
            CallAudioRouteControl(audio: callAudio)
        }
        .onAppear { callAudio.refreshAvailableAudioRoutes() }
    }

    private var incomingCallID: UInt8? {
        if case .incoming(let id) = lifecycle.phase { return id }
        return nil
    }

    private var isActive: Bool {
        if case .active = lifecycle.phase { return true }
        return false
    }

    private var callTitle: String {
        let number = voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if let callID = lifecycle.phase.callID,
           let call = voiceControl.calls.first(where: { $0.id == callID }) {
            if call.direction == 2 || call.remoteNumberPresentation != nil {
                return call.remotePartyDisplayText
            }
        }
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

/// Shared presentation only: all side effects are supplied by the caller.
private struct CallScreenLayout<RouteControl: View>: View {
    let callTitle: String
    let statusText: String
    let isRecording: Bool
    let isMuted: Bool
    let isActive: Bool
    let incomingCallID: UInt8?
    let callID: UInt8?
    let canSelectAudioRoute: Bool
    let recordingErrorText: String
    let audioRouteErrorText: String
    let onAnswer: (UInt8) -> Void
    let onEnd: (UInt8) -> Void
    let onToggleMute: () -> Void
    let onToggleRecording: () -> Void
    @ViewBuilder let routeControl: () -> RouteControl

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
                    .foregroundStyle(isRecording ? .red : .white.opacity(0.68))

                Circle()
                    .fill(.white.opacity(0.13))
                    .frame(width: 120, height: 120)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                if let callID = incomingCallID {
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
                    routeControl()
                        .disabled(!isActive || !canSelectAudioRoute)
                        .opacity(isActive && canSelectAudioRoute ? 1 : 0.45)
                    HStack(spacing: 54) {
                        CallActionButton(
                            title: "静音",
                            systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                            color: isMuted ? .white : .white.opacity(0.18),
                            foreground: isMuted ? .black : .white,
                            action: onToggleMute
                        )
                        .disabled(!isActive)
                        .opacity(isActive ? 1 : 0.45)

                        CallActionButton(
                            title: isRecording ? "停止录音" : "录音",
                            systemImage: isRecording ? "stop.fill" : "record.circle",
                            color: isRecording ? .red : .white.opacity(0.18),
                            action: onToggleRecording
                        )
                        .disabled(!isActive)
                        .opacity(isActive ? 1 : 0.45)
                    }

                    if !recordingErrorText.isEmpty {
                        Text(recordingErrorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if !audioRouteErrorText.isEmpty {
                        Text(audioRouteErrorText)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    if let callID {
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
}

/// No live coordinators, module commands or audio sessions are used here.
private struct CallScreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var incoming = false
    @State private var muted = false
    @State private var recordingStarted: Date?
    @State private var connectedAt = Date()
    @State private var selectedRoute = "receiver"

    private let routes: [CallAudioRoute] = [
        .init(kind: .receiver, title: "听筒", systemImage: "ear"),
        .init(kind: .speaker, title: "扬声器", systemImage: "speaker.wave.2.fill"),
        .init(kind: .accessory(uid: "preview"), title: "蓝牙耳机", systemImage: "headphones")
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            CallScreenLayout(
                callTitle: "示例联系人", statusText: status(at: context.date),
                isRecording: recordingStarted != nil, isMuted: muted,
                isActive: !incoming, incomingCallID: incoming ? 1 : nil,
                callID: 1, canSelectAudioRoute: true,
                recordingErrorText: "", audioRouteErrorText: "",
                onAnswer: { _ in reset(incoming: false) },
                onEnd: { _ in dismiss() },
                onToggleMute: { muted.toggle() },
                onToggleRecording: { recordingStarted = recordingStarted == nil ? Date() : nil }
            ) {
                CallAudioRoutePicker(routes: routes, selectedID: selectedRoute) {
                    selectedRoute = $0.id
                }
            }
        }
        .overlay(alignment: .top) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("通话界面预览").font(.subheadline.weight(.semibold))
                    Text("模拟操作，不会拨号或录音").font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Menu {
                    Button("通话中") { reset(incoming: false) }
                    Button("收到来电") { reset(incoming: true) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("切换预览场景")
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭预览")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
    }

    private func status(at date: Date) -> String {
        if incoming { return "来电" }
        if let recordingStarted {
            return "● 录音中  \(phoneDurationText(max(0, date.timeIntervalSince(recordingStarted))))"
        }
        return phoneDurationText(max(0, date.timeIntervalSince(connectedAt)))
    }

    private func reset(incoming: Bool) {
        self.incoming = incoming
        muted = false
        recordingStarted = nil
        connectedAt = Date()
        selectedRoute = "receiver"
    }
}

private struct CallAudioRouteControl: View {
    @ObservedObject var audio: CallAudioCoordinator

    var body: some View {
        CallAudioRoutePicker(routes: audio.availableAudioRoutes,
                             selectedID: audio.availableAudioRoutes.first(where: audio.isSelectedAudioRoute)?.id,
                             onSelect: audio.selectAudioRoute)
    }
}

private struct CallAudioRoutePicker: View {
    let routes: [CallAudioRoute]
    let selectedID: String?
    let onSelect: (CallAudioRoute) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 10) {
            Text("通话音频")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
            ViewThatFits(in: .horizontal) {
                segments(minimumWidth: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    segments(minimumWidth: 88)
                }
            }
            .padding(5)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    private func segments(minimumWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(routes) { route in
                let selected = selectedID == route.id
                Button {
                    guard !selected else { return }
                    onSelect(route)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: route.systemImage)
                            .font(.system(size: 23, weight: .medium))
                            .frame(height: 26)
                        Text(route.title.replacingOccurrences(of: "蓝牙：", with: ""))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.72))
                    .frame(minWidth: max(68, minimumWidth), maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 19)
                                .fill(.white)
                                .matchedGeometryEffect(id: "audio-selection", in: selection)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 19))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(route.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1),
                   value: selectedID)
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
    @EnvironmentObject private var systemCalls: SystemCallCoordinator
    @Binding var isConfirmingUnpair: Bool
    let dismiss: () -> Void

    @StateObject private var recordingPlayer = CallRecordingPlayer()
    @State private var recordings: [CallRecordingInfo] = []
    @State private var recordingPendingDeletion: CallRecordingInfo?
    @State private var isShowingCallPreview = false

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
                    if voiceControl.canControlCalls {
                        NavigationLink {
                            ModuleNotificationSettingsView(
                                pairingKey: voiceControl.pairingKeyForUplinkProbe()
                            )
                        } label: {
                            Label("提醒设置", systemImage: "bell.badge")
                        }
                    }
                    if voiceControl.isConfigured {
                        Button("删除 iPhone 本机配对", role: .destructive) {
                            isConfirmingUnpair = true
                        }
                    }
                }

                Section("通话录音") {
                    NavigationLink {
                        recordingsPage
                    } label: {
                        LabeledContent {
                            Text("\(recordings.count) 段")
                        } label: {
                            Label("通话录音", systemImage: "waveform")
                        }
                    }
                }

                Section("诊断") {
                    Button {
                        isShowingCallPreview = true
                    } label: {
                        Label("通话界面预览", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        ConnectionLogView()
                    } label: {
                        Label("连接日志", systemImage: "list.bullet.rectangle")
                    }
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

                Section("后台来电") {
                    LabeledContent("CallKit", value: "已启用")
                    LabeledContent("PushKit", value: systemCalls.pushStateText)
                    if !systemCalls.hasVoIPToken {
                        Text("如果一直无法取得 VoIP token，需要在 Apple Developer 中启用 Push Notifications，并使用包含 APNs entitlement 的 provisioning profile 重新签名。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("当前版本通过 USB ECM 控制 QDC507 并传输电话 PCM，不使用 USB Audio。Bark 与 Web Push 可在 App 未运行时提醒；要直接唤起原生 CallKit 接听页，仍需 VoIP APNs。")
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
            .onDisappear { recordingPlayer.stop() }
            .fullScreenCover(isPresented: $isShowingCallPreview) {
                CallScreenPreview()
            }
        }
    }

    private var recordingsPage: some View {
        List {
            Section {
                if recordings.isEmpty {
                    ContentUnavailableView("暂无通话录音", systemImage: "waveform", description: Text("通话中保存的录音会显示在这里。"))
                } else {
                    ForEach(recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            isPlaying: recordingPlayer.isPlaying(recording),
                            onTogglePlayback: { recordingPlayer.toggle(recording) }
                        )
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                recordingPendingDeletion = recording
                            }
                        }
                    }
                }
            } footer: {
                Text("录音仅保存在本机，不进入 iCloud 备份。双声道 WAV 文件的左声道是本机麦克风，右声道是对端语音。")
            }
            if let error = recordingPlayer.errorText {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("通话录音")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadRecordings() }
        .onDisappear { recordingPlayer.stop() }
        .alert("删除这段录音？", isPresented: isConfirmingRecordingDeletion) {
            Button("删除", role: .destructive, action: deletePendingRecording)
            Button("取消", role: .cancel) { recordingPendingDeletion = nil }
        } message: {
            Text("删除后无法恢复，对应通话记录仍会保留。")
        }
    }

    private func reloadRecordings() {
        recordings = CallRecordingController.recordingItems()
    }

    private var isConfirmingRecordingDeletion: Binding<Bool> {
        Binding(
            get: { recordingPendingDeletion != nil },
            set: { if !$0 { recordingPendingDeletion = nil } }
        )
    }

    private func deletePendingRecording() {
        guard let recording = recordingPendingDeletion else { return }
        recordingPlayer.stop(ifPlaying: recording)
        do {
            try CallRecordingController.delete(recording)
            recordingPendingDeletion = nil
            reloadRecordings()
        } catch {
            recordingPlayer.report(error)
            recordingPendingDeletion = nil
        }
    }
}

private struct ConnectionLogView: View {
    @ObservedObject private var log = ConnectionLog.shared
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("记录本次 App 运行的连接、重试与短信状态，最多保留 300 条。时间为距离日志开始的耗时；退出 App 后不保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("不包含配对密钥、电话号码和短信正文。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if log.entries.isEmpty {
                Text("暂无连接记录").foregroundStyle(.secondary)
            }
            ForEach(log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.message)
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) · +\(String(format: "%.3f", entry.elapsed)) 秒")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
        .navigationTitle("连接日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("复制日志", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = log.exportText
                        copied = true
                    }
                    ShareLink(item: log.exportText) {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                    Button("清空日志", systemImage: "trash", role: .destructive) { log.clear() }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("日志操作")
            }
        }
        .alert("日志已复制", isPresented: $copied) { Button("好", role: .cancel) {} }
    }
}

struct RecordingRow: View {
    let recording: CallRecordingInfo
    let isPlaying: Bool
    let onTogglePlayback: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "暂停录音" : "播放录音")

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body.weight(.medium))
                Text("\(phoneDurationText(recording.duration)) · \(fileSizeText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ShareLink(item: recording.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("分享录音")
        }
        .padding(.vertical, 3)
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: recording.fileSize, countStyle: .file)
    }
}

@MainActor
final class CallRecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingURL: URL?
    @Published private(set) var isPlayingNow = false
    @Published private(set) var errorText: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0

    func isPlaying(_ recording: CallRecordingInfo) -> Bool {
        isPlayingNow && playingURL == recording.url
    }

    func canSeek(_ recording: CallRecordingInfo) -> Bool {
        playingURL == recording.url && player != nil
    }

    func toggle(_ recording: CallRecordingInfo) {
        playbackTask?.cancel()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                // prepareToPlay/play implicitly activate the session synchronously
                // when it is inactive. Activate explicitly before either call.
                let session = AVAudioSession.sharedInstance()
                if #available(iOS 27.0, *) {
                    guard try await session.activate(options: []) else {
                        throw NSError(domain: "CallRecordingPlayer", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "无法启用录音播放音频"])
                    }
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try AVAudioSession.sharedInstance().setActive(true)
                    }.value
                }
                guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                self.toggleActivatedRecording(recording)
            } catch {
                guard !Task.isCancelled, self.playbackGeneration == generation else { return }
                self.report(error)
            }
        }
    }

    private func toggleActivatedRecording(_ recording: CallRecordingInfo) {
        if playingURL == recording.url, let player {
            if player.isPlaying {
                player.pause()
                currentTime = player.currentTime
                isPlayingNow = false
                progressTask?.cancel()
                progressTask = nil
            } else {
                isPlayingNow = player.play()
                if isPlayingNow { startProgressUpdates() }
            }
            return
        }

        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.delegate = self
            self.player = player
            playingURL = recording.url
            currentTime = 0
            duration = player.duration
            isPlayingNow = player.play()
            errorText = isPlayingNow ? nil : "无法播放这段录音"
            if isPlayingNow { startProgressUpdates() }
        } catch {
            report(error)
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let target = min(max(0, time), player.duration)
        player.currentTime = target
        currentTime = target
    }

    func stop(ifPlaying recording: CallRecordingInfo) {
        guard playingURL == recording.url else { return }
        stop()
    }

    func stop() {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        playingURL = nil
        isPlayingNow = false
        currentTime = 0
        duration = 0
    }

    func report(_ error: Error) {
        stop()
        errorText = error.localizedDescription
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        progressTask?.cancel()
        progressTask = nil
        currentTime = player.duration
        duration = player.duration
        self.player = nil
        playingURL = nil
        isPlayingNow = false
        if !flag { errorText = "录音播放中断" }
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.isPlaying else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
