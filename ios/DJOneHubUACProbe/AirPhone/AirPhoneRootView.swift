import Contacts
import SwiftUI
import UniformTypeIdentifiers

enum PhoneTab: Hashable {
    case recents, contacts, keypad, messages
}

struct AirPhoneRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var callAudio: CallAudioCoordinator
    @EnvironmentObject private var contacts: ContactsModel
    @EnvironmentObject private var lifecycle: CallLifecycleCoordinator
    @EnvironmentObject private var systemCalls: SystemCallCoordinator
    @StateObject private var sms = SMSControlModel()
    @AppStorage(PhoneProductPreferences.automaticCallRecording)
    private var automaticCallRecordingEnabled = false

    @State private var selectedTab: PhoneTab = .keypad
    @State private var isConfirmingUnpair = false
    @State private var isConfirmingRecording = false
    @State private var isShowingSettings = false
    @State private var suppressedAutomaticRecordingCallID: UInt8?

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RecentsView(
                    onDial: prepareNumber,
                    onSettings: showSettings
                )
                    .tag(PhoneTab.recents)
                    .tabItem { Label("最近通话", systemImage: "clock.fill") }
                ContactsView(
                    onDial: prepareNumber,
                    onSettings: showSettings
                )
                    .tag(PhoneTab.contacts)
                    .tabItem { Label("通讯录", systemImage: "person.crop.circle.fill") }
                KeypadView(
                    onCall: { lifecycle.dial() },
                    onSettings: showSettings
                )
                    .tag(PhoneTab.keypad)
                    .tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3.fill") }
                MessagesView(
                    sms: sms,
                    onRefresh: refreshSMS,
                    onSettings: showSettings
                )
                    .tag(PhoneTab.messages)
                    .tabItem { Label("信息", systemImage: "message.fill") }
                    .badge(sms.unreadCount)
            }
            .modifier(ModuleBottomAccessory(onOpen: showSettings))
            .tabBarMinimizeIfAvailable()

            if shouldPresentCallScreen {
                InCallView(
                    onAnswer: systemCalls.requestAnswer,
                    onEnd: systemCalls.requestEnd,
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            voiceControl.refreshLongTermAuthorization()
            await runAutomaticSMSRefresh()
        }
        .onOpenURL { url in
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == "djonehub", parts.user == nil,
                  parts.password == nil, parts.port == nil, parts.query == nil,
                  parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return }
            switch parts.host?.lowercased() {
            case "calls": isShowingSettings = false; selectedTab = .recents
            case "messages": isShowingSettings = false; selectedTab = .messages; refreshSMS()
            case "module": isShowingSettings = true
            default: return
            }
            lifecycle.applicationDidBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            contacts.loadIfAuthorized()
        }
        .onChange(of: voiceControl.shouldPollStatus) { _, ready in
            if ready, scenePhase == .active { refreshSMS() }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .messages, scenePhase == .active { refreshSMS() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: ConnectionLog.shared.append("App 已回到前台")
            case .inactive: ConnectionLog.shared.append("App 暂时不活跃（系统交互或前后台切换）")
            case .background: systemCalls.restoreBackgroundRingtone(); ConnectionLog.shared.append("App 已进入后台（可能锁屏或切换 App）")
            @unknown default: break
            }
            if newPhase == .active {
                voiceControl.refreshLongTermAuthorization()
                lifecycle.applicationDidBecomeActive()
                contacts.loadIfAuthorized()
                refreshSMS()
            }
        }
        .onChange(of: lifecycle.phase) { _, newPhase in
            if shouldPresentCallScreen { isShowingSettings = false }
            systemCalls.synchronize(with: newPhase)
            handleCallPhaseForAutomaticRecording(newPhase)
        }
        .onChange(of: callAudio.isMediaEnabled) { _, _ in
            startAutomaticRecordingIfNeeded()
        }
        .sheet(isPresented: $isShowingSettings) {
            ModulePanelView(
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
            "删除这部 iPhone 上的测试配对？长期配对不会受到影响。",
            isPresented: $isConfirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("删除测试配对", role: .destructive) {
                voiceControl.unpairCurrentModule()
                lifecycle.pairingDidChange()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var shouldPresentCallScreen: Bool {
        lifecycle.shouldPresentCallScreen
    }

    private func prepareNumber(_ number: String) {
        voiceControl.dialNumber = number
        selectedTab = .keypad
    }

    private func showSettings() { isShowingSettings = true }

    private func refreshSMS() {
        guard !sms.isLoading else { return }
        // Give the authenticated control connection priority during USB setup;
        // defer the secondary SMS connection until STATUS has succeeded.
        guard voiceControl.shouldPollStatus else { return }
        sms.refresh(pairingKey: voiceControl.sessionKeyForModuleServices())
    }

    private func runAutomaticSMSRefresh() async {
        while !Task.isCancelled {
            refreshSMS()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

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

private extension View {
    @ViewBuilder
    func tabBarMinimizeIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
