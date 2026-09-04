import Foundation

@main
struct CallRecordingControllerOfflineTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJOneHubRecordingTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = CallRecordingController(recordingsDirectory: directory)
        let url = try recorder.start()
        precondition(url.lastPathComponent.hasPrefix("DJOneHub-"))
        precondition(!url.lastPathComponent.contains("formatter.string"), "filename interpolation failed")
        let uplink = pcmFrame(sample: 0x0123)
        let downlink = pcmFrame(sample: -0x1234)
        recorder.appendUplink(uplink)
        recorder.appendDownlink(downlink)
        let completedURL = try recorder.stop()
        precondition(completedURL == url, "recording URL changed")

        let data = try Data(contentsOf: url)
        precondition(data.count == 44 + 512, "unexpected WAV size: \(data.count)")
        precondition(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        precondition(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        precondition(String(data: data[36..<40], encoding: .ascii) == "data")
        precondition(littleEndianUInt32(data, offset: 40) == 512)
        precondition(data[44] == 0x48 && data[45] == 0x1B, "uplink gain/channel 1 is incorrect")
        precondition(data[46] == 0xCC && data[47] == 0xED, "downlink is not channel 2")

        let clippedPositive = CallRecordingController.applyUplinkRecordingGain(pcmFrame(sample: 3_000))
        precondition(clippedPositive[0] == 0xFF && clippedPositive[1] == 0x7F)
        let clippedNegative = CallRecordingController.applyUplinkRecordingGain(pcmFrame(sample: -3_000))
        precondition(clippedNegative[0] == 0x00 && clippedNegative[1] == 0x80)

        let info = try unwrap(CallRecordingController.recordingInfo(for: url))
        precondition(info.fileSize == Int64(data.count))
        precondition(abs(info.duration - 0.016) < 0.000_001, "unexpected duration: \(info.duration)")

        let secondURL = try recorder.start()
        _ = try recorder.stop()
        precondition(secondURL != url, "recording filenames must be unique")
        print("call recording offline test passed")
    }

    private static func pcmFrame(sample: Int16) -> Data {
        var value = sample.littleEndian
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        var data = Data(capacity: CallRecordingController.frameBytes)
        for _ in 0..<(CallRecordingController.frameBytes / 2) {
            data.append(contentsOf: bytes)
        }
        return data
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "CallRecordingControllerOfflineTest", code: 1)
        }
        return value
    }
}
