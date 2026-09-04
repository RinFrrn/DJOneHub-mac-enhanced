import SwiftUI

@main
@MainActor
struct DJOneHubApp: App {
    @StateObject private var voiceControl: VoiceControlModel
    @StateObject private var callAudio: CallAudioCoordinator
    @StateObject private var history: CallHistoryStore
    @StateObject private var contacts: ContactsModel
    @StateObject private var lifecycle: CallLifecycleCoordinator

    init() {
        let voiceControl = VoiceControlModel()
        let callAudio = CallAudioCoordinator()
        let history = CallHistoryStore()
        let contacts = ContactsModel()
        _voiceControl = StateObject(wrappedValue: voiceControl)
        _callAudio = StateObject(wrappedValue: callAudio)
        _history = StateObject(wrappedValue: history)
        _contacts = StateObject(wrappedValue: contacts)
        _lifecycle = StateObject(
            wrappedValue: CallLifecycleCoordinator(
                voiceControl: voiceControl,
                callAudio: callAudio,
                history: history
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            DJOneHubRootView()
                .environmentObject(voiceControl)
                .environmentObject(callAudio)
                .environmentObject(history)
                .environmentObject(contacts)
                .environmentObject(lifecycle)
        }
    }
}
