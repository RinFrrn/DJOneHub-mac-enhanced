import SwiftUI
import UniformTypeIdentifiers

enum PhoneTab: Hashable {
    case recents, contacts, keypad, messages
}

struct DJOneHubRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var callAudio: CallAudioCoordinator
    @EnvironmentObject private var contacts: ContactsModel
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @AppStorage(PhoneProductPreferences.automaticCallRecording)
    private var automaticCallRecordingEnabled = false

    @State private var selectedTab: PhoneTab = .keypad
    @State private var isConfirmingDial = false
    @State private var isConfirmingUnpair = false
    @State private var isConfirmingRecording = false
    @State private var isShowingSettings = false
    @State private var suppressedAutomaticRecordingCallID: UInt8?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RecentsView(onDial: prepareNumber, onSettings: showSettings)
                    .tag(PhoneTab.recents)
                    .tabItem { Label("最近通话", systemImage: "clock.fill") }
                ContactsView(onDial: prepareNumber, onSettings: showSettings)
                    .tag(PhoneTab.contacts)
                    .tabItem { Label("通讯录", systemImage: "person.crop.circle.fill") }
                KeypadView(onCall: { isConfirmingDial = true }, onSettings: showSettings)
                    .tag(PhoneTab.keypad)
                    .tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3.fill") }
                MessagesView(onSettings: showSettings)
                    .tag(PhoneTab.messages)
                    .tabItem { Label("信息", systemImage: "message.fill") }
            }

            if shouldPresentCallScreen {
                InCallView(
                    onAnswer: lifecycle.answer,
                    onEnd: lifecycle.end,
                    onToggleMute: lifecycle.toggleMute,
                    onToggleRecording: toggleRecording
                )
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 1), value: shouldPresentCallScreen)
        .task {
            lifecycle.start()
            contacts.loadIfAuthorized()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                lifecycle.applicationDidBecomeActive()
                contacts.loadIfAuthorized()
            }
        }
        .onChange(of: lifecycle.phase) { _, newPhase in
            handleCallPhaseForAutomaticRecording(newPhase)
        }
        .onChange(of: callAudio.isMediaEnabled) { _, _ in
            startAutomaticRecordingIfNeeded()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                isConfirmingUnpair: $isConfirmingUnpair,
                dismiss: { isShowingSettings = false }
            )
        }
        .fileImporter(
            isPresented: $voiceControl.isImportingPairing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importPairing
        )
        .confirmationDialog(
            "确认拨打 \(trimmedDialNumber)？",
            isPresented: $isConfirmingDial,
            titleVisibility: .visible
        ) {
            Button("拨打") { lifecycle.dial() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "开始通话录音？",
            isPresented: $isConfirmingRecording,
            titleVisibility: .visible
        ) {
            Button("开始录音") {
                beginRecording()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("录音会将你的声音和对方声音保存为仅在本机可见的 WAV 文件。请先确认已取得必要同意并遵守当地法律。")
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

    private var shouldPresentCallScreen: Bool {
        switch lifecycle.phase {
        case .placingCall, .dialing, .incoming, .answering, .active, .ending: return true
        default: return false
        }
    }

    private var trimmedDialNumber: String {
        voiceControl.dialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareNumber(_ number: String) {
        voiceControl.dialNumber = number
        selectedTab = .keypad
    }

    private func showSettings() { isShowingSettings = true }

    private func toggleRecording() {
        if callAudio.isRecording {
            if automaticCallRecordingEnabled, case .active(let callID) = lifecycle.phase {
                suppressedAutomaticRecordingCallID = callID
            }
            callAudio.stopRecording()
        } else {
            isConfirmingRecording = true
        }
    }

    private func beginRecording() {
        if let url = callAudio.startRecording() {
            lifecycle.attachRecording(url)
        }
    }

    private func handleCallPhaseForAutomaticRecording(_ phase: ProductCallPhase) {
        switch phase {
        case .active:
            startAutomaticRecordingIfNeeded()
        case .ready, .needsPairing, .needsControlPairing:
            suppressedAutomaticRecordingCallID = nil
        default:
            break
        }
    }

    private func startAutomaticRecordingIfNeeded() {
        guard automaticCallRecordingEnabled,
              case .active(let callID) = lifecycle.phase,
              suppressedAutomaticRecordingCallID != callID,
              callAudio.isRunning,
              callAudio.isMediaEnabled,
              !callAudio.isRecording else { return }
        beginRecording()
    }

    private func importPairing(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            voiceControl.importDevelopmentPairingBundle(try Data(contentsOf: url))
            lifecycle.pairingDidChange()
        } catch {
            voiceControl.reportPairingImportFailure(error)
        }
    }
}
