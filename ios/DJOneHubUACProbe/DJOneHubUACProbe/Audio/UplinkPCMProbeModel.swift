import AVFAudio
import Foundation
import Network

@MainActor
final class UplinkPCMProbeModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isTestTone = false
    @Published private(set) var stateText = "停止"
    @Published private(set) var detailText = ""
    @Published private(set) var sentFrames: UInt64 = 0
    @Published private(set) var receivedFrames: UInt64 = 0
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var downlinkLevel: Double = 0
    @Published private(set) var inputFormatText = "—"

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pipeline: UplinkPacketPipeline?
    private var downlinkPlayer: DownlinkPCMPlayer?

    func start(pairingKey: Data) {
        guard !isRunning else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        stateText = "请求麦克风权限…"
        detailText = ""
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.stateText = "麦克风权限被拒绝"
                    self.detailText = "请在系统设置中允许 DJOneHub UAC Probe 使用麦克风"
                    return
                }
                self.startAuthorized(pairingKey: pairingKey)
            }
        }
    }

    func stop() {
        guard isRunning || engine != nil || pipeline != nil else { return }
        let input = engine?.inputNode
        input?.removeTap(onBus: 0)
        engine?.stop()
        downlinkPlayer?.stop()
        pipeline?.stop()
        pipeline = nil
        converter = nil
        downlinkPlayer = nil
        engine = nil
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        isTestTone = false
        stateText = "已停止"
        detailText = "模块侧将在 3 秒无合法包后关闭 Media1 通话 PCM"
        inputLevel = 0
        downlinkLevel = 0
    }

    func startTestTone(pairingKey: Data) {
        guard !isRunning else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        var sessionID: UInt32 = 0
        while sessionID == 0 {
            sessionID = UInt32.random(in: 1 ... UInt32.max)
        }
        let pipeline = makePipeline(pairingKey: pairingKey, sessionID: sessionID)
        self.pipeline = pipeline
        sentFrames = 0
        receivedFrames = 0
        inputLevel = 0.25
        downlinkLevel = 0
        inputFormatText = "1000 Hz 固定音 → 8000 Hz / 1 ch / S16_LE"
        stateText = "连接模块 UDP…"
        detailText = "固定峰值 8192/32768；用于隔离麦克风采集问题"
        isTestTone = true
        isRunning = true
        pipeline.start()
        pipeline.startTestTone()
    }

    private func startAuthorized(pairingKey: Data) {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.016)
            try session.setActive(true)
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMic)
            }
            // A connected QDC507 also advertises a USB Audio playback sink.
            // defaultToSpeaker does not override that external route, so force
            // the receiver side of this ECM bridge back to the iPhone speaker.
            try session.overrideOutputAudioPort(.speaker)
            guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) else {
                throw ProbeError.builtInMicrophoneNotSelected
            }
            guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                throw ProbeError.builtInSpeakerNotSelected
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 8_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ProbeError.converterUnavailable
            }

            var sessionID: UInt32 = 0
            while sessionID == 0 {
                sessionID = UInt32.random(in: 1 ... UInt32.max)
            }
            let player = AVAudioPlayerNode()
            let downlinkPlayer = DownlinkPCMPlayer(player: player, format: outputFormat)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            let pipeline = makePipeline(
                pairingKey: pairingKey,
                sessionID: sessionID,
                downlinkPlayer: downlinkPlayer
            )

            input.installTap(onBus: 0, bufferSize: 768, format: inputFormat) { buffer, _ in
                do {
                    let converted = try Self.convert(buffer, using: converter, outputFormat: outputFormat)
                    if !converted.pcm.isEmpty {
                        pipeline.enqueue(converted.pcm, peak: converted.peak)
                    }
                } catch {
                    pipeline.fail("8 kHz PCM 转换失败：\(error.localizedDescription)")
                }
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.converter = converter
            self.pipeline = pipeline
            self.downlinkPlayer = downlinkPlayer
            sentFrames = 0
            receivedFrames = 0
            inputLevel = 0
            downlinkLevel = 0
            inputFormatText = String(
                format: "%.0f Hz / %u ch → 8000 Hz / 1 ch / S16_LE",
                inputFormat.sampleRate,
                inputFormat.channelCount
            )
            stateText = "连接模块 UDP…"
            detailText = "双向 PCM：内置麦克风上行，modem 下行送往 iPhone 扬声器"
            isTestTone = false
            isRunning = true
            pipeline.start()
        } catch {
            pipeline?.stop()
            pipeline = nil
            converter = nil
            downlinkPlayer?.stop()
            downlinkPlayer = nil
            engine = nil
            try? session.overrideOutputAudioPort(.none)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            isRunning = false
            stateText = "无法启动 PCM 上行"
            detailText = error.localizedDescription
        }
    }

    private func makePipeline(
        pairingKey: Data,
        sessionID: UInt32,
        downlinkPlayer: DownlinkPCMPlayer? = nil
    ) -> UplinkPacketPipeline {
        UplinkPacketPipeline(
            pairingKey: pairingKey,
            sessionID: sessionID,
            onState: { [weak self] state in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.stateText = state
                }
            },
            onProgress: { [weak self] frames, peak in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.sentFrames = frames
                    self.inputLevel = peak
                }
            },
            onDownlink: { [weak self] sequence, pcm, frames in
                let peak = Self.normalizedPCM16Peak(pcm)
                downlinkPlayer?.enqueue(sequence: sequence, pcm: pcm)
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.receivedFrames = frames
                    self.downlinkLevel = peak
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.stop()
                    self.stateText = "PCM 发送失败"
                    self.detailText = error
                }
            }
        )
    }

    func playDownlinkDiagnosticTone() {
        guard isRunning, !isTestTone, let downlinkPlayer else { return }
        downlinkPlayer.enqueueDiagnosticTone()
    }

    nonisolated private static func normalizedPCM16Peak(_ pcm: Data) -> Double {
        guard pcm.count >= MemoryLayout<Int16>.size else { return 0 }
        var peak: Int32 = 0
        pcm.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for sample in samples {
                peak = max(peak, abs(Int32(Int16(littleEndian: sample))))
            }
        }
        return min(1, Double(peak) / Double(Int16.max))
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> (pcm: Data, peak: Double) {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ProbeError.outputBufferUnavailable
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw ProbeError.conversionFailed }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else {
            return (Data(), 0)
        }
        let count = Int(output.frameLength)
        var peak: Int32 = 0
        for index in 0 ..< count {
            peak = max(peak, abs(Int32(samples[index])))
        }
        return (
            Data(bytes: samples, count: count * MemoryLayout<Int16>.size),
            min(1, Double(peak) / Double(Int16.max))
        )
    }

    private enum ProbeError: Error, LocalizedError {
        case builtInMicrophoneNotSelected
        case builtInSpeakerNotSelected
        case inputFormatUnavailable
        case converterUnavailable
        case outputBufferUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .builtInMicrophoneNotSelected: return "iOS 没有采用内置麦克风，已拒绝发送以避免回声环路"
            case .builtInSpeakerNotSelected: return "iOS 仍将下行送往模块 USB Audio，未切换到 iPhone 扬声器"
            case .inputFormatUnavailable: return "无法读取麦克风 PCM 格式"
            case .converterUnavailable: return "无法创建 8 kHz S16_LE 转换器"
            case .outputBufferUnavailable: return "无法分配 8 kHz PCM 缓冲区"
            case .conversionFailed: return "AVAudioConverter 返回错误"
            }
        }
    }
}

private final class DownlinkPCMPlayer: @unchecked Sendable {
    private static let startupFrameCount = 4
    private static let maximumBufferedFrameCount = 16

    private let queue = DispatchQueue(label: "DJOneHub.DownlinkPCM")
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var jitterBuffer = DownlinkJitterBuffer()
    private var bufferedFrames = 0
    private var started = false
    private var stopped = false

    init(player: AVAudioPlayerNode, format: AVAudioFormat) {
        self.player = player
        self.format = format
    }

    func enqueue(sequence: UInt32, pcm: Data) {
        queue.async { [self] in
            let result = jitterBuffer.push(sequence: sequence, pcm: pcm)
            for frame in result.frames {
                scheduleLocked(frame.pcm)
            }
        }
    }

    func enqueueDiagnosticTone() {
        queue.async { [self] in
            guard !stopped else { return }
            var sampleIndex = 0
            for _ in 0 ..< 32 {
                var samples = [Int16](
                    repeating: 0,
                    count: Int(UplinkAudioProtocol.samplesPerFrame)
                )
                for index in samples.indices {
                    let phase = 2 * Double.pi * 700 * Double(sampleIndex) / 8_000
                    samples[index] = Int16(sin(phase) * 8_192)
                    sampleIndex += 1
                }
                scheduleLocked(samples.withUnsafeBytes { Data($0) })
            }
        }
    }

    private func scheduleLocked(_ pcm: Data) {
        guard !stopped,
              bufferedFrames < Self.maximumBufferedFrameCount,
              pcm.count == UplinkAudioProtocol.pcmBytes,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(UplinkAudioProtocol.samplesPerFrame)
              ) else { return }
            buffer.frameLength = AVAudioFrameCount(UplinkAudioProtocol.samplesPerFrame)
            guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
                return
            }
            pcm.withUnsafeBytes { source in
                guard let sourceAddress = source.baseAddress else { return }
                memcpy(destination, sourceAddress, pcm.count)
            }
            bufferedFrames += 1
            player.scheduleBuffer(buffer) { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.bufferedFrames = max(0, self.bufferedFrames - 1)
                    if self.started, self.bufferedFrames == 0 {
                        self.player.pause()
                        self.started = false
                    }
                }
            }
            if !started, bufferedFrames >= Self.startupFrameCount {
                player.play()
                started = true
            }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            player.stop()
            jitterBuffer.reset()
            bufferedFrames = 0
            started = false
        }
    }
}

private final class UplinkPacketPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DJOneHub.UplinkPCM")
    private let pairingKey: Data
    private let sessionID: UInt32
    private let onState: @Sendable (String) -> Void
    private let onProgress: @Sendable (UInt64, Double) -> Void
    private let onDownlink: @Sendable (UInt32, Data, UInt64) -> Void
    private let onError: @Sendable (String) -> Void
    private var connection: NWConnection?
    private var toneTimer: DispatchSourceTimer?
    private var toneSampleIndex: UInt64 = 0
    private var pendingPCM = Data()
    private var sequence: UInt32 = 0
    private var frames: UInt64 = 0
    private var downlinkFrames: UInt64 = 0
    private var stopped = false

    init(
        pairingKey: Data,
        sessionID: UInt32,
        onState: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (UInt64, Double) -> Void,
        onDownlink: @escaping @Sendable (UInt32, Data, UInt64) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.pairingKey = pairingKey
        self.sessionID = sessionID
        self.onState = onState
        self.onProgress = onProgress
        self.onDownlink = onDownlink
        self.onError = onError
    }

    func start() {
        queue.async { [self] in
            guard !stopped, let port = NWEndpoint.Port(rawValue: 45_751) else { return }
            let parameters = NWParameters.udp
            parameters.requiredInterfaceType = .wiredEthernet
            let connection = NWConnection(host: "192.168.225.1", port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    switch state {
                    case .ready:
                        self.onState("双向 PCM 传输中")
                        self.receiveDownlinkLocked(connection)
                    case .failed(let error):
                        self.failLocked("UDP 连接失败：\(error.localizedDescription)")
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveDownlinkLocked(_ connection: NWConnection) {
        guard !stopped else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if let error {
                    self.failLocked("UDP 下行接收失败：\(error.localizedDescription)")
                    return
                }
                if let data, !data.isEmpty {
                    do {
                        let frame = try UplinkAudioProtocol.decodeDownlink(
                            data,
                            pairingKey: self.pairingKey,
                            sessionID: self.sessionID
                        )
                        self.downlinkFrames &+= 1
                        self.onDownlink(frame.sequence, frame.pcm, self.downlinkFrames)
                    } catch {
                        self.failLocked(error.localizedDescription)
                        return
                    }
                }
                self.receiveDownlinkLocked(connection)
            }
        }
    }

    func enqueue(_ pcm: Data, peak: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            pendingPCM.append(pcm)
            while pendingPCM.count >= UplinkAudioProtocol.pcmBytes {
                let frame = Data(pendingPCM.prefix(UplinkAudioProtocol.pcmBytes))
                pendingPCM.removeFirst(UplinkAudioProtocol.pcmBytes)
                sequence &+= 1
                if sequence == 0 { sequence = 1 }
                do {
                    let packet = try UplinkAudioProtocol.encodeUplink(
                        pairingKey: pairingKey,
                        sessionID: sessionID,
                        sequence: sequence,
                        pcm: frame
                    )
                    connection?.send(
                        content: packet,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard let self, let error else { return }
                            self.queue.async {
                                self.failLocked("UDP PCM 发送失败：\(error.localizedDescription)")
                            }
                        }
                    )
                    frames &+= 1
                } catch {
                    failLocked(error.localizedDescription)
                    return
                }
            }
            onProgress(frames, peak)
        }
    }

    func startTestTone() {
        queue.async { [self] in
            guard !stopped, toneTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let pattern: [Int16] = [0, 5_793, 8_192, 5_793, 0, -5_793, -8_192, -5_793]
                var samples = [Int16](repeating: 0, count: UplinkAudioProtocol.pcmBytes / 2)
                for index in samples.indices {
                    samples[index] = pattern[Int(self.toneSampleIndex % UInt64(pattern.count))]
                    self.toneSampleIndex &+= 1
                }
                let pcm = samples.withUnsafeBytes { Data($0) }
                self.enqueue(pcm, peak: 0.25)
            }
            toneTimer = timer
            timer.resume()
        }
    }

    func fail(_ message: String) {
        queue.async { [self] in failLocked(message) }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            toneTimer?.cancel()
            toneTimer = nil
            connection?.cancel()
            connection = nil
            pendingPCM.removeAll(keepingCapacity: false)
        }
    }

    private func failLocked(_ message: String) {
        guard !stopped else { return }
        stopped = true
        toneTimer?.cancel()
        toneTimer = nil
        connection?.cancel()
        connection = nil
        pendingPCM.removeAll(keepingCapacity: false)
        onError(message)
    }
}
