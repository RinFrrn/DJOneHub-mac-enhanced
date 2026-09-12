import Foundation

@main
struct DownlinkPlayoutQueueStateOfflineTest {
    static func main() {
        testStartupAndRebufferThresholds()
        testMaximumQueueDepth()
        testResetRejectsStaleCompletions()
        print("DownlinkPlayoutQueueStateOfflineTest: PASS")
    }

    private static func testStartupAndRebufferThresholds() {
        var state = DownlinkPlayoutQueueState()
        let generation = state.generation

        for _ in 0 ..< 3 {
            precondition(state.enqueue() == .scheduleOnly)
        }
        precondition(state.enqueue() == .scheduleAndPlay)
        precondition(state.isPlaying && state.bufferedFrames == 4)
        for _ in 0 ..< 3 {
            precondition(state.complete(generation: generation) == .none)
        }
        precondition(
            state.complete(generation: generation) == .pauseAndRebuffer
        )
        precondition(!state.isPlaying && state.bufferedFrames == 0)

        for _ in 0 ..< 5 {
            precondition(state.enqueue() == .scheduleOnly)
        }
        precondition(state.enqueue() == .scheduleAndPlay)
        precondition(state.isPlaying && state.bufferedFrames == 6)
    }

    private static func testMaximumQueueDepth() {
        var state = DownlinkPlayoutQueueState(
            configuration: .init(
                startupFrames: 2,
                rebufferFrames: 3,
                maximumBufferedFrames: 4
            )
        )

        precondition(state.enqueue() == .scheduleOnly)
        precondition(state.enqueue() == .scheduleAndPlay)
        precondition(state.enqueue() == .scheduleOnly)
        precondition(state.enqueue() == .scheduleOnly)
        precondition(state.enqueue() == .drop)
        precondition(state.bufferedFrames == 4)
    }

    private static func testResetRejectsStaleCompletions() {
        var state = DownlinkPlayoutQueueState(
            configuration: .init(
                startupFrames: 2,
                rebufferFrames: 3,
                maximumBufferedFrames: 4
            )
        )
        let staleGeneration = state.generation

        _ = state.enqueue()
        _ = state.enqueue()
        state.reset()
        let currentGeneration = state.generation
        precondition(currentGeneration != staleGeneration)
        _ = state.enqueue()
        precondition(state.enqueue() == .scheduleAndPlay)
        precondition(state.bufferedFrames == 2)
        precondition(
            state.complete(generation: staleGeneration) == .none
        )
        precondition(state.bufferedFrames == 2 && state.isPlaying)
        precondition(
            state.complete(generation: currentGeneration) == .none
        )
        precondition(state.bufferedFrames == 1 && state.isPlaying)
    }
}
