import SwiftUI

@main
@MainActor
struct AirPhoneApp: App {
    @StateObject private var voiceControl: VoiceControlModel
    @StateObject private var callAudio: CallAudioCoordinator
    @StateObject private var history: CallHistoryStore
    @StateObject private var contacts: ContactsModel
    @StateObject private var lifecycle: CallLifecycleCoordinator
    @StateObject private var systemCalls: SystemCallCoordinator

    init() {
        let voiceControl = VoiceControlModel()
        let callAudio = CallAudioCoordinator()
        let history = CallHistoryStore()
        let contacts = ContactsModel()
        _voiceControl = StateObject(wrappedValue: voiceControl)
        _callAudio = StateObject(wrappedValue: callAudio)
        _history = StateObject(wrappedValue: history)
        _contacts = StateObject(wrappedValue: contacts)
        let lifecycle = CallLifecycleCoordinator(
            voiceControl: voiceControl,
            callAudio: callAudio,
            history: history
        )
        let systemCalls = SystemCallCoordinator(
            voiceControl: voiceControl,
            lifecycle: lifecycle
        )
        systemCalls.start()
        _lifecycle = StateObject(wrappedValue: lifecycle)
        _systemCalls = StateObject(wrappedValue: systemCalls)
    }

    var body: some Scene {
        WindowGroup {
            AirPhoneRootView()
                .environmentObject(voiceControl)
                .environmentObject(callAudio)
                .environmentObject(history)
                .environmentObject(contacts)
                .environmentObject(lifecycle)
                .environmentObject(systemCalls)
        }
    }
}
