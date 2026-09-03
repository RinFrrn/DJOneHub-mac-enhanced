import SwiftUI

@main
@MainActor
struct DJOneHubApp: App {
    @StateObject private var voiceControl: VoiceControlModel
    @StateObject private var callAudio: CallAudioCoordinator
    @StateObject private var lifecycle: CallLifecycleCoordinator

    init() {
        let voiceControl = VoiceControlModel()
        let callAudio = CallAudioCoordinator()
        _voiceControl = StateObject(wrappedValue: voiceControl)
        _callAudio = StateObject(wrappedValue: callAudio)
        _lifecycle = StateObject(
            wrappedValue: CallLifecycleCoordinator(
                voiceControl: voiceControl,
                callAudio: callAudio
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            DJOneHubRootView()
                .environmentObject(voiceControl)
                .environmentObject(callAudio)
                .environmentObject(lifecycle)
        }
    }
}
