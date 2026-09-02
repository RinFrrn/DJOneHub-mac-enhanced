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
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var inputFormatText = "—"

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pipeline: UplinkPacketPipeline?

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
        pipeline?.stop()
        pipeline = nil
        converter = nil
        engine = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        isTestTone = false
        stateText = "已停止"
        detailText = "模块侧将在 3 秒无包后关闭 D5 并恢复原 UAC 状态"
        inputLevel = 0
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
        inputLevel = 0.25
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
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.016)
            try session.setActive(true)
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtInMic)
            }
            guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) else {
                throw ProbeError.builtInMicrophoneNotSelected
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
            let pipeline = makePipeline(pairingKey: pairingKey, sessionID: sessionID)

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
            sentFrames = 0
            inputLevel = 0
            inputFormatText = String(
                format: "%.0f Hz / %u ch → 8000 Hz / 1 ch / S16_LE",
                inputFormat.sampleRate,
                inputFormat.channelCount
            )
            stateText = "连接模块 UDP…"
            detailText = "只发送上行；不打开 USB Audio，不读取 D6"
            isTestTone = false
            isRunning = true
            pipeline.start()
        } catch {
            pipeline?.stop()
            pipeline = nil
            converter = nil
            engine = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            isRunning = false
            stateText = "无法启动 PCM 上行"
            detailText = error.localizedDescription
        }
    }

    private func makePipeline(pairingKey: Data, sessionID: UInt32) -> UplinkPacketPipeline {
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
        case inputFormatUnavailable
        case converterUnavailable
        case outputBufferUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .builtInMicrophoneNotSelected: return "iOS 没有采用内置麦克风，已拒绝发送以避免回声环路"
            case .inputFormatUnavailable: return "无法读取麦克风 PCM 格式"
            case .converterUnavailable: return "无法创建 8 kHz S16_LE 转换器"
            case .outputBufferUnavailable: return "无法分配 8 kHz PCM 缓冲区"
            case .conversionFailed: return "AVAudioConverter 返回错误"
            }
        }
    }
}

private final class UplinkPacketPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DJOneHub.UplinkPCM")
    private let pairingKey: Data
    private let sessionID: UInt32
    private let onState: @Sendable (String) -> Void
    private let onProgress: @Sendable (UInt64, Double) -> Void
    private let onError: @Sendable (String) -> Void
    private var connection: NWConnection?
    private var toneTimer: DispatchSourceTimer?
    private var toneSampleIndex: UInt64 = 0
    private var pendingPCM = Data()
    private var sequence: UInt32 = 0
    private var frames: UInt64 = 0
    private var stopped = false

    init(
        pairingKey: Data,
        sessionID: UInt32,
        onState: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (UInt64, Double) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.pairingKey = pairingKey
        self.sessionID = sessionID
        self.onState = onState
        self.onProgress = onProgress
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
                        self.onState("上行发送中")
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
