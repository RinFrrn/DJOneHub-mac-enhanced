import Foundation

struct DownlinkPlayoutFrame: Equatable {
    let sequence: UInt32
    let pcm: Data
    let concealed: Bool
}

struct DownlinkJitterPushResult: Equatable {
    let frames: [DownlinkPlayoutFrame]
    let dropped: Bool
    let reset: Bool
}

/// Small, bounded reorder window for the fixed 16 ms downlink stream.
///
/// This type has no timers or audio dependencies, so its packet policy can be
/// tested offline. A gap is concealed only after enough newer packets arrive;
/// isolated reordering therefore does not become an audible silence frame.
struct DownlinkJitterBuffer {
    struct Configuration {
        var frameBytes = UplinkAudioProtocol.pcmBytes
        var reorderWindow = 3
        var maximumSequenceJump: Int32 = 64
    }

    private let configuration: Configuration
    private var expectedSequence: UInt32?
    private var pending: [UInt32: Data] = [:]

    init(configuration: Configuration = .init()) {
        precondition(configuration.frameBytes > 0)
        precondition(configuration.reorderWindow > 0)
        precondition(configuration.maximumSequenceJump > 0)
        self.configuration = configuration
    }

    mutating func push(sequence: UInt32, pcm: Data) -> DownlinkJitterPushResult {
        guard sequence != 0, pcm.count == configuration.frameBytes else {
            return DownlinkJitterPushResult(frames: [], dropped: true, reset: false)
        }

        if expectedSequence == nil {
            expectedSequence = sequence
        }

        var didReset = false
        if let expectedSequence, sequence != expectedSequence {
            let delta = Int32(bitPattern: sequence &- expectedSequence)
            if delta <= 0 {
                return DownlinkJitterPushResult(frames: [], dropped: true, reset: false)
            }
            if delta > configuration.maximumSequenceJump {
                pending.removeAll(keepingCapacity: true)
                self.expectedSequence = sequence
                didReset = true
            }
        }

        guard pending[sequence] == nil else {
            return DownlinkJitterPushResult(frames: [], dropped: true, reset: didReset)
        }
        pending[sequence] = pcm

        var output: [DownlinkPlayoutFrame] = []
        drainContiguous(into: &output)
        while !pending.isEmpty, pending.count >= configuration.reorderWindow,
              let missing = expectedSequence {
            output.append(
                DownlinkPlayoutFrame(
                    sequence: missing,
                    pcm: Data(count: configuration.frameBytes),
                    concealed: true
                )
            )
            expectedSequence = Self.nextSequence(after: missing)
            drainContiguous(into: &output)
        }

        return DownlinkJitterPushResult(frames: output, dropped: false, reset: didReset)
    }

    mutating func reset() {
        expectedSequence = nil
        pending.removeAll(keepingCapacity: false)
    }

    private mutating func drainContiguous(into output: inout [DownlinkPlayoutFrame]) {
        while let expected = expectedSequence,
              let pcm = pending.removeValue(forKey: expected) {
            output.append(
                DownlinkPlayoutFrame(sequence: expected, pcm: pcm, concealed: false)
            )
            expectedSequence = Self.nextSequence(after: expected)
        }
    }

    private static func nextSequence(after sequence: UInt32) -> UInt32 {
        sequence == UInt32.max ? 1 : sequence + 1
    }
}

