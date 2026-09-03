import Foundation

@main
struct DownlinkJitterBufferOfflineTest {
    static func main() {
        testInOrderAndDuplicate()
        testReordering()
        testLossConcealment()
        testSequenceWrap()
        testLargeJumpReset()
        testInvalidFrame()
        testPlaybackMetrics()
        print("DownlinkJitterBufferOfflineTest: PASS")
    }

    private static func testInOrderAndDuplicate() {
        var buffer = DownlinkJitterBuffer()
        let first = buffer.push(sequence: 1, pcm: pcm(1))
        precondition(first.frames == [frame(1, value: 1)])
        precondition(buffer.push(sequence: 1, pcm: pcm(1)).dropped)
        precondition(buffer.push(sequence: 2, pcm: pcm(2)).frames == [frame(2, value: 2)])
    }

    private static func testReordering() {
        var buffer = DownlinkJitterBuffer()
        _ = buffer.push(sequence: 10, pcm: pcm(10))
        precondition(buffer.push(sequence: 12, pcm: pcm(12)).frames.isEmpty)
        let reordered = buffer.push(sequence: 11, pcm: pcm(11))
        precondition(reordered.reordered)
        precondition(reordered.frames == [frame(11, value: 11), frame(12, value: 12)])
    }

    private static func testLossConcealment() {
        var buffer = DownlinkJitterBuffer()
        _ = buffer.push(sequence: 20, pcm: pcm(20))
        _ = buffer.push(sequence: 23, pcm: pcm(23))
        _ = buffer.push(sequence: 24, pcm: pcm(24))
        let result = buffer.push(sequence: 25, pcm: pcm(25))
        precondition(result.frames.count == 5)
        precondition(result.frames[0].sequence == 21 && result.frames[0].concealed)
        precondition(result.frames[1].sequence == 22 && result.frames[1].concealed)
        precondition(result.frames[2...] == [frame(23, value: 23), frame(24, value: 24), frame(25, value: 25)][...])
    }

    private static func testSequenceWrap() {
        var buffer = DownlinkJitterBuffer()
        precondition(buffer.push(sequence: UInt32.max, pcm: pcm(1)).frames.count == 1)
        let wrapped = buffer.push(sequence: 1, pcm: pcm(2))
        precondition(wrapped.frames == [frame(1, value: 2)])
    }

    private static func testLargeJumpReset() {
        var buffer = DownlinkJitterBuffer()
        _ = buffer.push(sequence: 1, pcm: pcm(1))
        let reset = buffer.push(sequence: 100, pcm: pcm(2))
        precondition(reset.reset)
        precondition(reset.frames == [frame(100, value: 2)])
    }

    private static func testInvalidFrame() {
        var buffer = DownlinkJitterBuffer()
        precondition(buffer.push(sequence: 0, pcm: pcm(1)).dropped)
        precondition(buffer.push(sequence: 1, pcm: Data()).dropped)
    }

    private static func testPlaybackMetrics() {
        var metrics = DownlinkPlaybackMetrics()
        var buffer = DownlinkJitterBuffer()

        metrics.record(buffer.push(sequence: 10, pcm: pcm(10)))
        metrics.record(buffer.push(sequence: 12, pcm: pcm(12)))
        metrics.record(buffer.push(sequence: 11, pcm: pcm(11)))
        metrics.record(buffer.push(sequence: 11, pcm: pcm(11)))
        metrics.record(buffer.push(sequence: 100, pcm: pcm(100)))
        metrics.record(buffer.push(sequence: 103, pcm: pcm(103)))
        metrics.record(buffer.push(sequence: 104, pcm: pcm(104)))
        metrics.record(buffer.push(sequence: 105, pcm: pcm(105)))
        metrics.recordRebuffer()
        metrics.recordQueueDrop()

        precondition(metrics.reorderedPackets == 1)
        precondition(metrics.concealedFrames == 2)
        precondition(metrics.droppedPackets == 1)
        precondition(metrics.sequenceResets == 1)
        precondition(metrics.rebufferEvents == 1)
        precondition(metrics.queueDroppedFrames == 1)
    }

    private static func pcm(_ value: UInt8) -> Data {
        Data(repeating: value, count: UplinkAudioProtocol.pcmBytes)
    }

    private static func frame(_ sequence: UInt32, value: UInt8) -> DownlinkPlayoutFrame {
        DownlinkPlayoutFrame(sequence: sequence, pcm: pcm(value), concealed: false)
    }
}
