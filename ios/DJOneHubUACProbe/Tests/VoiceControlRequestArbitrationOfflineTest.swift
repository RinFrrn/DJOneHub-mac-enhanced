@main
struct VoiceControlRequestArbitrationOfflineTest {
    static func main() {
        var arbitration = VoiceControlRequestArbitration()

        precondition(arbitration.begin(.backgroundStatus) == .start)
        precondition(!arbitration.isForegroundBusy)
        precondition(arbitration.begin(.backgroundStatus) == .reject)

        precondition(arbitration.begin(.foreground) == .preemptBackground)
        precondition(arbitration.isForegroundBusy)
        precondition(arbitration.begin(.backgroundStatus) == .reject)
        precondition(arbitration.begin(.foreground) == .reject)

        arbitration.finish(.backgroundStatus)
        precondition(arbitration.isForegroundBusy)
        arbitration.finish(.foreground)
        precondition(!arbitration.isForegroundBusy)

        precondition(arbitration.begin(.foreground) == .start)
        precondition(arbitration.isForegroundBusy)
        arbitration.reset()
        precondition(!arbitration.isForegroundBusy)

        print("VoiceControlRequestArbitrationOfflineTest: PASS")
    }
}
