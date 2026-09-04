import Foundation

struct CallRecordingInfo: Identifiable, Equatable, Sendable {
    let url: URL
    let createdAt: Date
    let fileSize: Int64
    let duration: TimeInterval

    var id: URL { url }
    var filename: String { url.lastPathComponent }
}

enum CallRecordingError: Error, LocalizedError {
    case alreadyRecording
    case cannotCreateDirectory
    case recordingTooLarge

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "已有通话录音正在进行"
        case .cannotCreateDirectory:
            return "无法创建通话录音目录"
        case .recordingTooLarge:
            return "录音文件超过 WAV 格式支持的大小"
        }
    }
}

/// Records the authenticated 8 kHz PCM streams without touching the system
/// call-audio route. Channel 1 is the local microphone; channel 2 is the
/// remote party. All file I/O stays on a private serial queue.
final class CallRecordingController: @unchecked Sendable {
    static let sampleRate: UInt32 = 8_000
    static let channelCount: UInt16 = 2
    static let bitsPerSample: UInt16 = 16
    static let frameBytes = 256

    private let queue = DispatchQueue(label: "DJOneHub.CallRecording")
    private let directoryOverride: URL?
    private var session: RecordingSession?

    init(recordingsDirectory: URL? = nil) {
        directoryOverride = recordingsDirectory
    }

    var isRecording: Bool {
        queue.sync { session != nil }
    }

    @discardableResult
    func start() throws -> URL {
        try queue.sync {
            guard session == nil else { throw CallRecordingError.alreadyRecording }
            let directory = try directoryOverride ?? Self.recordingsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let filename = "DJOneHub-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).wav"
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
#if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
#endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)

            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data(repeating: 0, count: 44))
            session = RecordingSession(url: url, handle: handle)
            return url
        }
    }

    func appendUplink(_ pcm: Data) {
        append(pcm, direction: .uplink)
    }

    func appendDownlink(_ pcm: Data) {
        append(pcm, direction: .downlink)
    }

    @discardableResult
    func stop() throws -> URL? {
        try queue.sync {
            guard let session else { return nil }
            self.session = nil
            return try session.finish()
        }
    }

    static func recordings() -> [URL] {
        recordingItems().map(\.url)
    }

    static func recordingItems() -> [CallRecordingInfo] {
        guard let directory = try? recordingsDirectory() else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .compactMap(recordingInfo(for:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func recording(named filename: String) -> CallRecordingInfo? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.lowercased().hasSuffix(".wav"),
              let directory = try? recordingsDirectory() else { return nil }
        return recordingInfo(for: directory.appendingPathComponent(filename, isDirectory: false))
    }

    static func recordingInfo(for url: URL) -> CallRecordingInfo? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let rawSize = values.fileSize,
              rawSize >= 44 else { return nil }
        let dataBytes = rawSize - 44
        let bytesPerSecond = Int(sampleRate) * Int(channelCount) * Int(bitsPerSample / 8)
        guard bytesPerSecond > 0 else { return nil }
        return CallRecordingInfo(
            url: url,
            createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
            fileSize: Int64(rawSize),
            duration: TimeInterval(dataBytes) / TimeInterval(bytesPerSecond)
        )
    }

    static func delete(_ recording: CallRecordingInfo) throws {
        let directory = try recordingsDirectory().standardizedFileURL
        let target = recording.url.standardizedFileURL
        guard target.deletingLastPathComponent() == directory,
              target.pathExtension.lowercased() == "wav" else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.removeItem(at: target)
    }

    private enum Direction {
        case uplink
        case downlink
    }

    private func append(_ pcm: Data, direction: Direction) {
        guard pcm.count == Self.frameBytes else { return }
        queue.async { [weak self] in
            guard let session = self?.session else { return }
            do {
                switch direction {
                case .uplink: try session.appendUplink(pcm)
                case .downlink: try session.appendDownlink(pcm)
                }
            } catch {
                try? session.abort()
                self?.session = nil
            }
        }
    }

    private static func recordingsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CallRecordingError.cannotCreateDirectory
        }
        let directory = documents.appendingPathComponent("通话录音", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class RecordingSession {
    private static let silence = Data(repeating: 0, count: CallRecordingController.frameBytes)
    private static let maximumSkewFrames = 4

    let url: URL
    private let handle: FileHandle
    private var uplinkFrames: [Data] = []
    private var downlinkFrames: [Data] = []
    private var dataByteCount: UInt64 = 0
    private var isClosed = false

    init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }

    func appendUplink(_ pcm: Data) throws {
        guard !isClosed else { return }
        uplinkFrames.append(pcm)
        try drainBalancedFrames()
    }

    func appendDownlink(_ pcm: Data) throws {
        guard !isClosed else { return }
        downlinkFrames.append(pcm)
        try drainBalancedFrames()
    }

    func finish() throws -> URL {
        guard !isClosed else { return url }
        while !uplinkFrames.isEmpty || !downlinkFrames.isEmpty {
            let uplink = uplinkFrames.isEmpty ? Self.silence : uplinkFrames.removeFirst()
            let downlink = downlinkFrames.isEmpty ? Self.silence : downlinkFrames.removeFirst()
            try writeStereo(uplink: uplink, downlink: downlink)
        }
        guard dataByteCount <= UInt64(UInt32.max - 36) else {
            try abort()
            throw CallRecordingError.recordingTooLarge
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.wavHeader(dataBytes: UInt32(dataByteCount)))
        try handle.close()
        isClosed = true
        return url
    }

    func abort() throws {
        guard !isClosed else { return }
        try handle.close()
        isClosed = true
        try? FileManager.default.removeItem(at: url)
    }

    private func drainBalancedFrames() throws {
        while !uplinkFrames.isEmpty && !downlinkFrames.isEmpty {
            try writeStereo(
                uplink: uplinkFrames.removeFirst(),
                downlink: downlinkFrames.removeFirst()
            )
        }
        while uplinkFrames.count > Self.maximumSkewFrames {
            try writeStereo(uplink: uplinkFrames.removeFirst(), downlink: Self.silence)
        }
        while downlinkFrames.count > Self.maximumSkewFrames {
            try writeStereo(uplink: Self.silence, downlink: downlinkFrames.removeFirst())
        }
    }

    private func writeStereo(uplink: Data, downlink: Data) throws {
        var stereo = Data(capacity: CallRecordingController.frameBytes * 2)
        for offset in stride(from: 0, to: CallRecordingController.frameBytes, by: 2) {
            stereo.append(uplink[offset])
            stereo.append(uplink[offset + 1])
            stereo.append(downlink[offset])
            stereo.append(downlink[offset + 1])
        }
        try handle.write(contentsOf: stereo)
        dataByteCount += UInt64(stereo.count)
    }

    private static func wavHeader(dataBytes: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(CallRecordingController.channelCount)
        data.appendLittleEndian(CallRecordingController.sampleRate)
        let blockAlign = CallRecordingController.channelCount * (CallRecordingController.bitsPerSample / 8)
        data.appendLittleEndian(CallRecordingController.sampleRate * UInt32(blockAlign))
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(CallRecordingController.bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataBytes)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
