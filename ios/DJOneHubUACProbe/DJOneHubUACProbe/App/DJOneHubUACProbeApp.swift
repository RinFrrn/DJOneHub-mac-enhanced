import SwiftUI

@main
struct DJOneHubUACProbeApp: App {
    @StateObject private var audioProbe = AudioProbeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioProbe)
        }
    }
}
