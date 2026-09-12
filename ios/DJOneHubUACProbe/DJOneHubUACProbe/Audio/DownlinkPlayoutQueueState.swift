import Foundation

struct DownlinkPlayoutQueueState {
    struct Configuration: Equatable, Sendable {
        var startupFrames = 4
        var rebufferFrames = 6
        var maximumBufferedFrames = 16
    }

    enum EnqueueDecision: Equatable {
        case scheduleOnly
        case scheduleAndPlay
        case drop
    }

    enum CompletionDecision: Equatable {
        case none
        case pauseAndRebuffer
    }

    private let configuration: Configuration
    private(set) var bufferedFrames = 0
    private(set) var isPlaying = false
    private(set) var generation: UInt64 = 0
    private var hasPlayed = false

    init(configuration: Configuration = .init()) {
        precondition(configuration.startupFrames > 0)
        precondition(configuration.rebufferFrames > 0)
        precondition(
            configuration.maximumBufferedFrames >= configuration.startupFrames
        )
        precondition(
            configuration.maximumBufferedFrames >= configuration.rebufferFrames
        )
        self.configuration = configuration
    }

    mutating func enqueue() -> EnqueueDecision {
        guard bufferedFrames < configuration.maximumBufferedFrames else {
            return .drop
        }
        bufferedFrames += 1
        let target = hasPlayed
            ? configuration.rebufferFrames
            : configuration.startupFrames
        guard !isPlaying, bufferedFrames >= target else {
            return .scheduleOnly
        }
        isPlaying = true
        hasPlayed = true
        return .scheduleAndPlay
    }

    mutating func complete(generation completedGeneration: UInt64) -> CompletionDecision {
        guard completedGeneration == generation, bufferedFrames > 0 else {
            return .none
        }
        bufferedFrames -= 1
        guard isPlaying, bufferedFrames == 0 else {
            return .none
        }
        isPlaying = false
        return .pauseAndRebuffer
    }

    mutating func reset() {
        generation &+= 1
        bufferedFrames = 0
        isPlaying = false
        hasPlayed = false
    }
}
