import Foundation

struct DownlinkPlaybackMetrics: Equatable, Sendable {
    private(set) var reorderedPackets: UInt64 = 0
    private(set) var concealedFrames: UInt64 = 0
    private(set) var droppedPackets: UInt64 = 0
    private(set) var sequenceResets: UInt64 = 0
    private(set) var rebufferEvents: UInt64 = 0
    private(set) var queueDroppedFrames: UInt64 = 0

    mutating func record(_ result: DownlinkJitterPushResult) {
        if result.reordered {
            reorderedPackets &+= 1
        }
        concealedFrames &+= UInt64(result.frames.lazy.filter(\.concealed).count)
        if result.dropped {
            droppedPackets &+= 1
        }
        if result.reset {
            sequenceResets &+= 1
        }
    }

    mutating func recordRebuffer() {
        rebufferEvents &+= 1
    }

    mutating func recordQueueDrop() {
        queueDroppedFrames &+= 1
    }
}
