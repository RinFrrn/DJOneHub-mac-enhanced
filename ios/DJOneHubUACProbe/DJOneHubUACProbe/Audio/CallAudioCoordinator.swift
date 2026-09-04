import AVFAudio
import Foundation

@MainActor
final class CallAudioCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isMediaEnabled = false
    @Published private(set) var isUplinkEnabled = false
    @Published private(set) var isDownlinkEnabled = false
    @Published private(set) var isLocalRingbackEnabled = false
    @Published private(set) var isTestTone = false
    @Published private(set) var isInterrupted = false
    @Published private(set) var hasActiveRequest = false
    @Published private(set) var isAwaitingRecovery = false
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
    private var playerNode: AVAudioPlayerNode?
    private var networkFormat: AVAudioFormat?
    private var notificationObservers: [NSObjectProtocol] = []
    private var desiredUplinkEnabled = false
    private var desiredDownlinkEnabled = false
    private var desiredLocalRingbackEnabled = false
    private var startGeneration: UInt64 = 0
    private var routeRecoveryState = AudioRouteRecoveryState()
    private var routeSettleTask: Task<Void, Never>?
    private var routeRecoveryReason = "音频路由发生变化"
    private var interruptedRouteSettleTask: Task<Void, Never>?
    private var interruptedRouteRevision: UInt64 = 0
    private var interruptedRouteRetryNotBefore: ContinuousClock.Instant?

    init() {
        observeAudioSession()
    }

    deinit {
        routeSettleTask?.cancel()
        interruptedRouteSettleTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(
        pairingKey: Data,
        uplinkEnabled: Bool = true,
        downlinkEnabled: Bool = true,
        localRingbackEnabled: Bool = false
    ) {
        guard !isRunning,
              !hasActiveRequest,
              !isInterrupted,
              routeSettleTask == nil,
              !routeRecoveryState.isRecoveryPending else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        startGeneration &+= 1
        let generation = startGeneration
        desiredUplinkEnabled = uplinkEnabled
        desiredDownlinkEnabled = downlinkEnabled
        desiredLocalRingbackEnabled = localRingbackEnabled
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        isAwaitingRecovery = false
        hasActiveRequest = true
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 1,
            interleaved: true
        ) else {
            hasActiveRequest = false
            stateText = "无法启动"
            detailText = "无法创建 8 kHz S16_LE 音频格式"
            return
        }
        var sessionID: UInt32 = 0
        while sessionID == 0 {
            sessionID = UInt32.random(in: 1 ... UInt32.max)
        }
        let player = AVAudioPlayerNode()
        let downlinkPlayer = makeDownlinkPlayer(
            player: player,
            format: outputFormat,
            mediaEnabled: false,
            generation: generation
        )
        let pipeline = makePipeline(
            pairingKey: pairingKey,
            sessionID: sessionID,
            mediaEnabled: false,
            downlinkPlayer: downlinkPlayer,
            generation: generation
        )
        self.pipeline = pipeline
        self.downlinkPlayer = downlinkPlayer
        playerNode = player
        networkFormat = outputFormat
        pipeline.start()
        stateText = uplinkEnabled || downlinkEnabled ? "请求麦克风权限…" : "正在预热通话音频…"
        detailText = downlinkEnabled && !uplinkEnabled
            ? "将播放回铃音和运营商提示；麦克风在接通后放行"
            : ""
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self,
                      self.startGeneration == generation,
                      self.hasActiveRequest else { return }
                guard granted else {
                    self.startGeneration &+= 1
                    self.tearDownAudio(deactivateSession: false)
                    self.hasActiveRequest = false
                    self.stateText = "麦克风权限被拒绝"
                    self.detailText = "请在系统设置中允许 DJOneHub 使用麦克风"
                    return
                }
                guard !self.isInterrupted else {
                    self.startGeneration &+= 1
                    self.tearDownAudio(deactivateSession: false)
                    self.hasActiveRequest = false
                    self.stateText = "系统音频暂时不可用"
                    self.detailText = "音频中断结束且通话仍存在时会自动恢复"
                    return
                }
                self.startAuthorized(generation: generation)
            }
        }
    }

    func setMediaEnabled(uplink: Bool, downlink: Bool, localRingback: Bool) {
        guard !isTestTone else { return }
        desiredUplinkEnabled = uplink
        desiredDownlinkEnabled = downlink
        desiredLocalRingbackEnabled = localRingback
        guard isRunning else { return }
        pipeline?.setMediaEnabled(uplink)
        downlinkPlayer?.setMediaEnabled(downlink)
        downlinkPlayer?.setLocalRingbackEnabled(localRingback)
        applyMediaState(uplink: uplink, downlink: downlink)
    }

    func stop(reason: String? = nil) {
        resetRouteRecoveryTracking()
        startGeneration &+= 1
        hasActiveRequest = false
        isRunning = false
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        desiredUplinkEnabled = false
        desiredDownlinkEnabled = false
        desiredLocalRingbackEnabled = false
        isTestTone = false
        isAwaitingRecovery = false
        tearDownAudio(deactivateSession: true)
        stateText = reason == nil ? "已停止" : "连接中断，PCM 已停止"
        detailText = reason ?? "模块侧将在 3 秒无合法包后关闭 Media1 通话 PCM"
        inputLevel = 0
        downlinkLevel = 0
    }

    func markControlRecoveredIfNeeded() {
        guard !isRunning,
              !hasActiveRequest,
              stateText == "连接中断，PCM 已停止" else { return }
        stateText = "连接已恢复"
        detailText = "已重新认证模块通话状态；当前没有需要恢复的 PCM 会话"
    }

    private func tearDownAudio(
        deactivateSession: Bool,
        clearOutputOverride: Bool = true
    ) {
        let input = engine?.inputNode
        input?.removeTap(onBus: 0)
        engine?.stop()
        downlinkPlayer?.stop()
        pipeline?.stop()
        pipeline = nil
        converter = nil
        downlinkPlayer = nil
        playerNode = nil
        networkFormat = nil
        engine = nil
        if clearOutputOverride {
            try? session.overrideOutputAudioPort(.none)
        }
        if deactivateSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func startTestTone(pairingKey: Data) {
        guard !isRunning,
              !hasActiveRequest,
              routeSettleTask == nil,
              !routeRecoveryState.isRecoveryPending else { return }
        guard pairingKey.count == 32 else {
            stateText = "无法启动"
            detailText = "当前配对凭据无效"
            return
        }
        startGeneration &+= 1
        let generation = startGeneration
        desiredUplinkEnabled = true
        desiredDownlinkEnabled = true
        desiredLocalRingbackEnabled = false
        isAwaitingRecovery = false
        hasActiveRequest = true
        var sessionID: UInt32 = 0
        while sessionID == 0 {
            sessionID = UInt32.random(in: 1 ... UInt32.max)
        }
        let pipeline = makePipeline(
            pairingKey: pairingKey,
            sessionID: sessionID,
            generation: generation
        )
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
        isMediaEnabled = true
        isUplinkEnabled = true
        isDownlinkEnabled = true
        isLocalRingbackEnabled = false
        pipeline.start()
        pipeline.startTestTone()
    }

    private func startAuthorized(generation: UInt64) {
        guard !isInterrupted,
              startGeneration == generation,
              hasActiveRequest else { return }
        do {
            try activateBuiltInCallRoute()

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw CallAudioError.inputFormatUnavailable
            }
            guard let outputFormat = networkFormat,
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw CallAudioError.converterUnavailable
            }
            guard let player = playerNode,
                  let downlinkPlayer,
                  let pipeline else {
                throw CallAudioError.prewarmUnavailable
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

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
            let uplinkEnabled = desiredUplinkEnabled
            let downlinkEnabled = desiredDownlinkEnabled
            let localRingbackEnabled = desiredLocalRingbackEnabled
            isTestTone = false
            isRunning = true
            isAwaitingRecovery = false
            resetRouteRecoveryTracking()
            pipeline.setMediaEnabled(uplinkEnabled)
            downlinkPlayer.setMediaEnabled(downlinkEnabled)
            downlinkPlayer.setLocalRingbackEnabled(localRingbackEnabled)
            applyMediaState(uplink: uplinkEnabled, downlink: downlinkEnabled)
        } catch {
            resetRouteRecoveryTracking()
            startGeneration &+= 1
            pipeline?.stop()
            pipeline = nil
            converter = nil
            downlinkPlayer?.stop()
            downlinkPlayer = nil
            playerNode = nil
            networkFormat = nil
            engine = nil
            try? session.overrideOutputAudioPort(.none)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            isRunning = false
            isMediaEnabled = false
            isUplinkEnabled = false
            isDownlinkEnabled = false
            isLocalRingbackEnabled = false
            isAwaitingRecovery = false
            hasActiveRequest = false
            stateText = "无法启动 PCM 上行"
            detailText = error.localizedDescription
        }
    }

    private func makePipeline(
        pairingKey: Data,
        sessionID: UInt32,
        mediaEnabled: Bool = true,
        downlinkPlayer: DownlinkPCMPlayer? = nil,
        generation: UInt64
    ) -> PCMTransport {
        PCMTransport(
            pairingKey: pairingKey,
            sessionID: sessionID,
            mediaEnabled: mediaEnabled,
            onState: { [weak self] state in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning else { return }
                    if self.desiredUplinkEnabled && self.desiredDownlinkEnabled {
                        self.stateText = state
                    } else if self.desiredDownlinkEnabled {
                        self.stateText = "下行 PCM 传输中"
                    } else {
                        self.stateText = "通话音频已预热"
                    }
                }
            },
            onProgress: { [weak self] frames, peak in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning else { return }
                    self.sentFrames = frames
                    self.inputLevel = peak
                }
            },
            onDownlink: { [weak self] sequence, pcm, frames in
                let peak = Self.normalizedPCM16Peak(pcm)
                // Each pipeline captures its own player. The player's serial
                // queue rejects frames after stop(), so audio packets stay off
                // MainActor while stale UI updates are generation-gated below.
                downlinkPlayer?.enqueue(sequence: sequence, pcm: pcm)
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning,
                          self.desiredDownlinkEnabled else { return }
                    self.receivedFrames = frames
                    self.downlinkLevel = peak
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning || self.hasActiveRequest else { return }
                    self.stop()
                    self.requestRecovery(error)
                    self.stateText = "PCM 发送失败，准备恢复"
                }
            }
        )
    }

    private func makeDownlinkPlayer(
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        mediaEnabled: Bool,
        generation: UInt64
    ) -> DownlinkPCMPlayer {
        DownlinkPCMPlayer(
            player: player,
            format: format,
            mediaEnabled: mediaEnabled,
            onMetrics: { [weak self] metrics in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning else { return }
                    self.downlinkMetrics = metrics
                }
            }
        )
    }

    private func applyMediaState(uplink: Bool, downlink: Bool) {
        isUplinkEnabled = uplink
        isDownlinkEnabled = downlink
        isLocalRingbackEnabled = desiredLocalRingbackEnabled && downlink
        isMediaEnabled = uplink || downlink
        inputLevel = uplink ? inputLevel : 0
        downlinkLevel = downlink ? downlinkLevel : 0
        if uplink && downlink {
            stateText = "双向 PCM 传输中"
            detailText = "双向 PCM：内置麦克风上行，modem 下行送往 iPhone 扬声器"
        } else if downlink {
            stateText = "下行 PCM 传输中"
            detailText = "正在播放回铃音和运营商提示；麦克风上行尚未放行"
        } else {
            stateText = "通话音频已预热"
            detailText = "仅发送认证静音保活；麦克风和下行尚未放行"
        }
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
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification)
                }
            }
        ]
    }

    private func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        if isInterrupted {
            let retryWindowIsOpen = interruptedRouteRetryNotBefore.map {
                ContinuousClock.now >= $0
            } ?? true
            if retryWindowIsOpen, Self.canRetryInterruptedRoute(after: rawReason) {
                scheduleInterruptedRouteSettleCheck(reason: Self.routeChangeReason(rawReason))
            }
            return
        }
        guard !isTestTone else { return }
        let hasMediaResources = hasAudioResources
        guard hasMediaResources || routeRecoveryState.isRecoveryPending else { return }

        let reason = Self.routeChangeReason(rawReason)
        let routeMatchesPolicy = currentRouteMatchesPolicy
        let requiresImmediatePause = isRunning && !routeMatchesPolicy
        if requiresImmediatePause || !routeRecoveryState.isRecoveryPending {
            routeRecoveryReason = reason
        }
        _ = routeRecoveryState.noteRouteChange(requiresRecovery: requiresImmediatePause)
        if requiresImmediatePause {
            pauseForRouteRecovery(reason: reason)
        }
        scheduleRouteSettleCheck(revision: routeRecoveryState.revision)
    }

    private func scheduleRouteSettleCheck(revision: UInt64) {
        routeSettleTask?.cancel()
        routeSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.finishRouteSettleCheck(revision: revision)
        }
    }

    private func finishRouteSettleCheck(revision: UInt64) {
        routeSettleTask = nil
        let decision = routeRecoveryState.settledDecision(
            revision: revision,
            hasMediaResources: hasAudioResources,
            routeMatchesPolicy: currentRouteMatchesPolicy,
            isInterrupted: isInterrupted
        )
        switch decision {
        case .ignore:
            return
        case .requestRecovery:
            requestRecovery("音频路由已稳定，正在重新确认通话状态（\(routeRecoveryReason)）")
        case .pauseAndRequestRecovery:
            pauseForRouteRecovery(reason: routeRecoveryReason)
            requestRecovery("音频路由已稳定，正在重新确认通话状态（\(routeRecoveryReason)）")
        }
    }

    private func pauseForRouteRecovery(reason: String) {
        guard hasAudioResources else { return }
        startGeneration &+= 1
        isRunning = false
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        isTestTone = false
        isAwaitingRecovery = false
        hasActiveRequest = false
        tearDownAudio(deactivateSession: true)
        stateText = "音频路由变化，PCM 已暂停"
        detailText = "等待路由稳定后重新认证 STATUS：\(reason)"
        inputLevel = 0
        downlinkLevel = 0
    }

    private func resetRouteRecoveryTracking() {
        routeSettleTask?.cancel()
        routeSettleTask = nil
        routeRecoveryState.reset()
        routeRecoveryReason = "音频路由发生变化"
        cancelInterruptedRouteSettleCheck()
    }

    private var hasAudioResources: Bool {
        isRunning || hasActiveRequest || engine != nil || pipeline != nil
    }

    private var currentRouteMatchesPolicy: Bool {
        session.currentRoute.inputs.contains { $0.portType == .builtInMic }
            && session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    private func activateBuiltInCallRoute() throws {
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
        // A connected QDC507 may advertise a USB Audio playback sink. Keep
        // the ECM call on the iPhone even while other routes come and go.
        try session.overrideOutputAudioPort(.speaker)
        guard session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }) else {
            throw CallAudioError.builtInMicrophoneNotSelected
        }
        guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
            throw CallAudioError.builtInSpeakerNotSelected
        }
    }

    private func scheduleInterruptedRouteSettleCheck(reason: String) {
        interruptedRouteRevision &+= 1
        let revision = interruptedRouteRevision
        interruptedRouteSettleTask?.cancel()
        interruptedRouteSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled,
                  let self,
                  self.interruptedRouteRevision == revision,
                  self.isInterrupted else { return }
            self.interruptedRouteSettleTask = nil
            self.retryInterruptedRoute(reason: reason)
        }
    }

    private func retryInterruptedRoute(reason: String) {
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try activateBuiltInCallRoute()
            isInterrupted = false
            cancelInterruptedRouteSettleCheck()
            requestRecovery("蓝牙路由切换已稳定，正在重新确认通话状态（\(reason)）")
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            interruptedRouteRetryNotBefore = ContinuousClock.now.advanced(by: .seconds(1))
            stateText = "系统音频已暂停"
            detailText = "系统仍占用音频路由；等待中断结束或下一次设备连接变化"
        }
    }

    private func cancelInterruptedRouteSettleCheck() {
        interruptedRouteRevision &+= 1
        interruptedRouteSettleTask?.cancel()
        interruptedRouteSettleTask = nil
        interruptedRouteRetryNotBefore = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            let shouldRetryAsRouteChange = routeRecoveryState.isRecoveryPending
                || (hasAudioResources && !currentRouteMatchesPolicy)
                || Self.canRetryInterruptionWithoutEnded(notification)
            resetRouteRecoveryTracking()
            isInterrupted = true
            if isRunning || engine != nil || pipeline != nil {
                startGeneration &+= 1
                isRunning = false
                isMediaEnabled = false
                isUplinkEnabled = false
                isDownlinkEnabled = false
                isLocalRingbackEnabled = false
                isTestTone = false
                isAwaitingRecovery = false
                hasActiveRequest = false
                tearDownAudio(deactivateSession: false, clearOutputOverride: false)
            }
            stateText = "系统音频已暂停"
            detailText = "音频中断结束且通话仍存在时会自动恢复"
            inputLevel = 0
            downlinkLevel = 0
            if shouldRetryAsRouteChange {
                scheduleInterruptedRouteSettleCheck(reason: "系统音频中断或外接设备变化")
            }

        case .ended:
            cancelInterruptedRouteSettleCheck()
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
        resetRouteRecoveryTracking()
        startGeneration &+= 1
        isRunning = false
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        isTestTone = false
        isAwaitingRecovery = false
        hasActiveRequest = false
        tearDownAudio(deactivateSession: false)
        inputLevel = 0
        downlinkLevel = 0
        if needsRecovery {
            requestRecovery("iOS 音频服务已重置，正在确认通话状态")
        }
    }

    private func requestRecovery(_ reason: String) {
        recoveryGeneration &+= 1
        isAwaitingRecovery = true
        stateText = "等待恢复通话音频"
        detailText = reason
    }

    private static func routeChangeReason(_ rawValue: UInt) -> String {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else {
            return "未知原因 \(rawValue)"
        }
        switch reason {
        case .newDeviceAvailable: return "检测到新音频设备"
        case .oldDeviceUnavailable: return "原音频设备已断开"
        case .categoryChange: return "系统音频类别变化"
        case .override: return "系统音频输出被重设"
        case .wakeFromSleep: return "设备从休眠唤醒"
        case .noSuitableRouteForCategory: return "当前没有可用通话音频路由"
        case .routeConfigurationChange: return "系统音频路由配置变化"
        case .unknown: return "未知音频路由变化"
        @unknown default: return "未来音频路由变化 \(rawValue)"
        }
    }

    private static func canRetryInterruptedRoute(after rawValue: UInt) -> Bool {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else { return false }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .noSuitableRouteForCategory:
            return true
        case .routeConfigurationChange:
            return true
        case .categoryChange, .override, .unknown:
            return false
        @unknown default:
            return false
        }
    }

    private static func canRetryInterruptionWithoutEnded(_ notification: Notification) -> Bool {
        let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            ?? AVAudioSession.InterruptionReason.default.rawValue
        guard let reason = AVAudioSession.InterruptionReason(rawValue: rawReason) else { return false }
        switch reason {
        case .default, .routeDisconnected:
            return true
        case .appWasSuspended, .builtInMicMuted:
            return false
        @unknown default:
            return false
        }
    }

    private enum CallAudioError: Error, LocalizedError {
        case builtInMicrophoneNotSelected
        case builtInSpeakerNotSelected
        case inputFormatUnavailable
        case converterUnavailable
        case prewarmUnavailable
        case outputBufferUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .builtInMicrophoneNotSelected: return "iOS 没有采用内置麦克风，已拒绝发送以避免回声环路"
            case .builtInSpeakerNotSelected: return "iOS 仍将下行送往模块 USB Audio，未切换到 iPhone 扬声器"
            case .inputFormatUnavailable: return "无法读取麦克风 PCM 格式"
            case .converterUnavailable: return "无法创建 8 kHz S16_LE 转换器"
            case .prewarmUnavailable: return "模块 PCM 预热资源已失效"
            case .outputBufferUnavailable: return "无法分配 8 kHz PCM 缓冲区"
            case .conversionFailed: return "AVAudioConverter 返回错误"
            }
        }
    }
}
