import AVFAudio
import Foundation

@MainActor
final class CallAudioCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isTestTone = false
    @Published private(set) var isInterrupted = false
    @Published private(set) var hasActiveRequest = false
    @Published private(set) var recoveryGeneration: UInt64 = 0
    @Published private(set) var stateText = "停止"
    @Published private(set) var detailText = ""
    @Published private(set) var sentFrames: UInt64 = 0
    @Published private(set) var receivedFrames: UInt64 = 0
    @Published private(set) var downlinkMetrics = DownlinkPlaybackMetrics()
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var downlinkLevel: Double = 0
    @Published private(set) var inputFormatText = "—"

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pipeline: PCMTransport?
    private var downlinkPlayer: DownlinkPCMPlayer?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        observeAudioSession()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(pairingKey: Data) {
        guard !isRunning, !isInterrupted else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        hasActiveRequest = true
        stateText = "请求麦克风权限…"
        detailText = ""
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.stateText = "麦克风权限被拒绝"
                    self.detailText = "请在系统设置中允许 DJOneHub 使用麦克风"
                    return
                }
                guard !self.isInterrupted else {
                    self.stateText = "系统音频暂时不可用"
                    self.detailText = "音频中断结束且通话仍存在时会自动恢复"
                    return
                }
                self.startAuthorized(pairingKey: pairingKey)
            }
        }
    }

    func stop() {
        tearDownAudio(deactivateSession: true)
        hasActiveRequest = false
        isRunning = false
        isTestTone = false
        stateText = "已停止"
        detailText = "模块侧将在 3 秒无合法包后关闭 Media1 通话 PCM"
        inputLevel = 0
        downlinkLevel = 0
    }

    private func tearDownAudio(deactivateSession: Bool) {
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
        if deactivateSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func startTestTone(pairingKey: Data) {
        guard !isRunning else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        hasActiveRequest = true
        var sessionID: UInt32 = 0
        while sessionID == 0 {
            sessionID = UInt32.random(in: 1 ... UInt32.max)
        }
        let pipeline = makePipeline(pairingKey: pairingKey, sessionID: sessionID)
        self.pipeline = pipeline
        sentFrames = 0
        receivedFrames = 0
        downlinkMetrics = DownlinkPlaybackMetrics()
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
        guard !isInterrupted else { return }
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
                throw CallAudioError.builtInMicrophoneNotSelected
            }
            guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                throw CallAudioError.builtInSpeakerNotSelected
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw CallAudioError.inputFormatUnavailable
            }
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 8_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw CallAudioError.converterUnavailable
            }

            var sessionID: UInt32 = 0
            while sessionID == 0 {
                sessionID = UInt32.random(in: 1 ... UInt32.max)
            }
            let player = AVAudioPlayerNode()
            let downlinkPlayer = DownlinkPCMPlayer(
                player: player,
                format: outputFormat,
                onMetrics: { [weak self] metrics in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.downlinkMetrics = metrics
                    }
                }
            )
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
            downlinkMetrics = DownlinkPlaybackMetrics()
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
    ) -> PCMTransport {
        PCMTransport(
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
            throw CallAudioError.outputBufferUnavailable
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
        guard status != .error else { throw CallAudioError.conversionFailed }
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

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        ]
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            isInterrupted = true
            if isRunning || engine != nil || pipeline != nil {
                tearDownAudio(deactivateSession: false)
                isRunning = false
                isTestTone = false
            }
            stateText = "系统音频已暂停"
            detailText = "音频中断结束且通话仍存在时会自动恢复"
            inputLevel = 0
            downlinkLevel = 0

        case .ended:
            isInterrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                requestRecovery("系统音频中断已结束，正在确认通话状态")
            } else {
                stateText = "系统音频中断已结束"
                detailText = "等待模块通话状态确认"
                requestRecovery(detailText)
            }

        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        let needsRecovery = isRunning || engine != nil || pipeline != nil
        tearDownAudio(deactivateSession: false)
        isRunning = false
        isTestTone = false
        inputLevel = 0
        downlinkLevel = 0
        if needsRecovery {
            requestRecovery("iOS 音频服务已重置，正在确认通话状态")
        }
    }

    private func requestRecovery(_ reason: String) {
        recoveryGeneration &+= 1
        stateText = "等待恢复通话音频"
        detailText = reason
    }

    private enum CallAudioError: Error, LocalizedError {
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
