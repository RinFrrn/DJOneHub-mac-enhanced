import AVFAudio
import Foundation

struct CallAudioRoute: Identifiable, Hashable {
    enum Kind: Hashable {
        case receiver
        case speaker
        case accessory(uid: String)
    }

    let kind: Kind
    let title: String
    let systemImage: String

    var id: String {
        switch kind {
        case .receiver: return "receiver"
        case .speaker: return "speaker"
        case .accessory(let uid): return "accessory-\(uid)"
        }
    }

    var compactTitle: String {
        switch kind {
        case .receiver: return "听筒"
        case .speaker: return "扬声器"
        case .accessory:
            return systemImage == "headphones" ? "蓝牙" : "耳机"
        }
    }
}

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
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsedSeconds: UInt64 = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var recordingErrorText = ""
    @Published private(set) var availableAudioRoutes: [CallAudioRoute] = []
    @Published private(set) var selectedAudioRoute: CallAudioRoute?
    @Published private(set) var audioRouteErrorText = ""

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
    private var preferredAudioRoute: CallAudioRoute.Kind = .receiver
    private var sessionDeactivationTask: Task<Void, Never>?
    private var pendingAudioRouteSelection: CallAudioRoute.Kind?
    private var activeRouteSignature = ""
    private var activeBuiltInInputUID: String?
    private var outputSwitchTask: Task<Void, Never>?
    private var isSwitchingBuiltInOutput = false
    private let recordingController = CallRecordingController()
    private var recordingTimerTask: Task<Void, Never>?
    private var callKitOwnership = CallKitAudioOwnership.app

    var canStartSystemCallAudio: Bool { callKitOwnership.canStartMedia }

    func beginSystemCallAudio() {
        guard !callKitOwnership.isSystemManaged else { return }
        callKitOwnership.begin()
        suspendSystemCallAudio()
        trace("CallKit owns session; waiting for didActivate")
    }

    func prepareSystemCallAnswer() throws {
        // Configure the session before fulfilling CXAnswerCallAction. CallKit
        // activates it; media starts only after didActivate and fresh STATUS.
        try configureCallAudioSession()
    }

    func systemCallAudioDidActivate() {
        guard callKitOwnership.isSystemManaged else { return }
        callKitOwnership.activate()
        resetRouteRecoveryTracking()
        isInterrupted = false
        refreshAvailableAudioRoutes()
        trace("CallKit didActivate route=\(routeSummary)")
        requestRecovery("CallKit 已激活音频，正在确认通话状态")
    }

    func systemCallAudioDidDeactivate() {
        guard callKitOwnership.isSystemManaged else { return }
        callKitOwnership.deactivate()
        suspendSystemCallAudio()
        trace("CallKit didDeactivate; media suspended")
    }

    func endSystemCallAudio() {
        guard callKitOwnership.isSystemManaged else { return }
        stop()
        callKitOwnership = .app
        isInterrupted = false
        trace("CallKit session released")
    }

    private func suspendSystemCallAudio() {
        resetRouteRecoveryTracking()
        stopRecording()
        startGeneration &+= 1
        hasActiveRequest = false
        isRunning = false
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        isAwaitingRecovery = false
        tearDownAudio(deactivateSession: false, clearOutputOverride: false)
        stateText = "等待系统通话音频"
        detailText = "CallKit 激活音频后恢复 PCM"
    }

    init() {
        observeAudioSession()
        refreshAvailableAudioRoutes()
    }

    deinit {
        routeSettleTask?.cancel()
        interruptedRouteSettleTask?.cancel()
        recordingTimerTask?.cancel()
        outputSwitchTask?.cancel()
        _ = try? recordingController.stop()
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
        trace("start requested uplink=\(uplinkEnabled) downlink=\(downlinkEnabled) ringback=\(localRingbackEnabled) route=\(routeSummary)")
        guard !isRunning,
              !hasActiveRequest,
              callKitOwnership.canStartMedia,
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
                    self.trace("microphone permission denied")
                    self.startGeneration &+= 1
                    self.tearDownAudio(deactivateSession: false)
                    self.hasActiveRequest = false
                    self.stateText = "麦克风权限被拒绝"
                    self.detailText = "请在系统设置中允许 AirPhone 使用麦克风"
                    return
                }
                guard !self.isInterrupted else {
                    self.trace("start cancelled because audio session is interrupted")
                    self.startGeneration &+= 1
                    self.tearDownAudio(deactivateSession: false)
                    self.hasActiveRequest = false
                    self.stateText = "系统音频暂时不可用"
                    self.detailText = "音频中断结束且通话仍存在时会自动恢复"
                    return
                }
                await self.startAuthorized(generation: generation)
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

    var canSelectAudioRoute: Bool {
        isRunning && !isInterrupted && !availableAudioRoutes.isEmpty
    }

    func refreshAvailableAudioRoutes() {
        var routes = [
            CallAudioRoute(kind: .receiver, title: "听筒", systemImage: "phone.fill"),
            CallAudioRoute(kind: .speaker, title: "扬声器", systemImage: "speaker.wave.2.fill")
        ]
        let accessoryInputs = (session.availableInputs ?? []).filter { input in
            input.portType == .bluetoothHFP || input.portType == .bluetoothLE || input.portType == .headsetMic
        }
        routes.append(contentsOf: accessoryInputs.map { input in
            let isBluetooth = input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            return CallAudioRoute(
                kind: .accessory(uid: input.uid),
                title: isBluetooth ? "蓝牙：\(input.portName)" : input.portName,
                systemImage: isBluetooth ? "headphones" : "earbuds"
            )
        })

        if case .accessory(let uid) = preferredAudioRoute,
           !accessoryInputs.contains(where: { $0.uid == uid }) {
            preferredAudioRoute = .receiver
            pendingAudioRouteSelection = nil
            if isRunning {
                audioRouteErrorText = "外接耳机已断开，已切回听筒"
            }
        }

        availableAudioRoutes = routes
        selectedAudioRoute = routes.first(where: { $0.kind == preferredAudioRoute })
            ?? routes.first(where: { $0.kind == .receiver })
    }

    func selectAudioRoute(_ route: CallAudioRoute) {
        guard availableAudioRoutes.contains(route) else { return }
        preferredAudioRoute = route.kind
        pendingAudioRouteSelection = route.kind
        selectedAudioRoute = route
        audioRouteErrorText = ""

        guard canSelectAudioRoute else { return }
        Task { [weak self] in
            await self?.applySelectedAudioRoute(route)
        }
    }

    private func applySelectedAudioRoute(_ route: CallAudioRoute) async {
        let generation = startGeneration
        do {
            // The running call already owns an active session. Re-activation
            // can disturb the route while the user is selecting an output.
            guard generation == startGeneration, isRunning, !isInterrupted else { return }
            if activeBuiltInInputUID != nil,
               route.kind == .receiver || route.kind == .speaker {
                isSwitchingBuiltInOutput = true
                outputSwitchTask?.cancel()
            }
            try applyPreferredCallRoute()
            if isSwitchingBuiltInOutput {
                outputSwitchTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self else { return }
                    self.isSwitchingBuiltInOutput = false
                    self.outputSwitchTask = nil
                    guard self.startGeneration == generation else { return }
                    self.handleRouteChange(Notification(
                        name: AVAudioSession.routeChangeNotification,
                        userInfo: [AVAudioSessionRouteChangeReasonKey:
                            AVAudioSession.RouteChangeReason.override.rawValue]
                    ))
                }
            }
            refreshAvailableAudioRoutes()
            if currentRouteMatchesPolicy {
                pendingAudioRouteSelection = nil
            } else {
                detailText = "正在切换到\(route.title)…"
            }
        } catch {
            isSwitchingBuiltInOutput = false
            pendingAudioRouteSelection = nil
            audioRouteErrorText = error.localizedDescription
            refreshAvailableAudioRoutes()
        }
    }

    func isSelectedAudioRoute(_ route: CallAudioRoute) -> Bool {
        route.kind == preferredAudioRoute
    }

    func stop(reason: String? = nil) {
        trace("stop reason=\(reason ?? "normal") sent=\(sentFrames) received=\(receivedFrames)")
        stopRecording()
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
        preferredAudioRoute = .receiver
        pendingAudioRouteSelection = nil
        refreshAvailableAudioRoutes()
        stateText = reason == nil ? "已停止" : "连接中断，PCM 已停止"
        detailText = reason ?? "模块侧将在 3 秒无合法包后关闭 Media1 通话 PCM"
        inputLevel = 0
        downlinkLevel = 0
    }

    @discardableResult
    func startRecording() -> URL? {
        guard isRunning, isMediaEnabled, !isRecording else { return nil }
        do {
            let url = try recordingController.start()
            lastRecordingURL = url
            recordingErrorText = ""
            recordingElapsedSeconds = 0
            isRecording = true
            recordingTimerTask?.cancel()
            recordingTimerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.isRecording else { return }
                    self.recordingElapsedSeconds &+= 1
                }
            }
            return url
        } catch {
            recordingErrorText = error.localizedDescription
            return nil
        }
    }

    func stopRecording() {
        guard isRecording || recordingController.isRecording else { return }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        do {
            if let url = try recordingController.stop() {
                lastRecordingURL = url
            }
            recordingErrorText = ""
        } catch {
            recordingErrorText = error.localizedDescription
        }
        isRecording = false
        recordingElapsedSeconds = 0
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
        activeRouteSignature = ""
        activeBuiltInInputUID = nil
        if clearOutputOverride {
            try? session.overrideOutputAudioPort(.none)
        }
        if deactivateSession && !callKitOwnership.isSystemManaged {
            deactivateAppAudioSessionAfterTeardown()
        }
    }

    func startTestTone(pairingKey: Data) {
        guard !isRunning,
              !hasActiveRequest,
              callKitOwnership.canStartMedia,
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

    private func startAuthorized(generation: UInt64) async {
        guard !isInterrupted,
              callKitOwnership.canStartMedia,
              startGeneration == generation,
              hasActiveRequest else { return }
        do {
            trace("activating audio route before=\(routeSummary)")
            try await activatePreferredCallRoute()
            trace("audio route activated after=\(routeSummary)")

            guard !isInterrupted,
                  callKitOwnership.canStartMedia,
                  startGeneration == generation,
                  hasActiveRequest else { return }

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
            trace("audio engine started input=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")

            self.engine = engine
            self.converter = converter
            self.pipeline = pipeline
            self.downlinkPlayer = downlinkPlayer
            activeRouteSignature = currentRouteSignature
            activeBuiltInInputUID = builtInCallInputUID
            refreshAvailableAudioRoutes()
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
            trace("audio start failed: \(error.localizedDescription) route=\(routeSummary)")
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
            deactivateAppAudioSessionAfterTeardown()
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
        let recorder = recordingController
        return PCMTransport(
            pairingKey: pairingKey,
            sessionID: sessionID,
            mediaEnabled: mediaEnabled,
            onState: { [weak self] state in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning else { return }
                    self.trace("transport state=\(state)")
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
                    if frames != 0, frames.isMultiple(of: 250) {
                        self.trace("uplink frames=\(frames) peak=\(String(format: "%.3f", peak))")
                    }
                }
            },
            onUplinkFrame: { pcm in
                recorder.appendUplink(pcm)
            },
            onDownlink: { [weak self] sequence, pcm, frames in
                let peak = Self.normalizedPCM16Peak(pcm)
                recorder.appendDownlink(pcm)
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
                    if frames != 0, frames.isMultiple(of: 250) {
                        self.trace("downlink frames=\(frames) peak=\(String(format: "%.3f", peak))")
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self,
                          self.startGeneration == generation,
                          self.isRunning || self.hasActiveRequest else { return }
                    self.trace("transport error=\(error)")
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
        if isUplinkEnabled != uplink || isDownlinkEnabled != downlink {
            trace("media applied uplink=\(uplink) downlink=\(downlink)")
        }
        isUplinkEnabled = uplink
        isDownlinkEnabled = downlink
        isLocalRingbackEnabled = desiredLocalRingbackEnabled && downlink
        isMediaEnabled = uplink || downlink
        inputLevel = uplink ? inputLevel : 0
        downlinkLevel = downlink ? downlinkLevel : 0
        if uplink && downlink {
            stateText = "双向 PCM 传输中"
            detailText = "双向 PCM：模块下行送往\(selectedAudioRoute?.title ?? "当前音频设备")"
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
        // Ignore transient routes while iOS clears the speaker override and
        // selects the built-in input. Evaluate the settled output once below.
        guard !isSwitchingBuiltInOutput else { return }
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        trace("route changed reason=\(Self.routeChangeReason(rawReason)) route=\(routeSummary) interrupted=\(isInterrupted)")
        refreshAvailableAudioRoutes()
        reconcilePreferredRouteAfterSystemChange(rawReason: rawReason)
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

        let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        let reason = Self.routeChangeReason(rawReason)
        let routeIsAcceptable = currentRouteIsAcceptableForRecovery
        // Receiver/speaker share the built-in capture format. Keep the engine,
        // authenticated UDP peer and recording alive for this output-only swap.
        // Bluetooth and USB changes still take the full recovery path.
        if isRunning, let engine,
           let activeBuiltInInputUID,
           activeBuiltInInputUID == builtInCallInputUID,
           currentRouteMatchesPolicy,
           let converter,
           engine.inputNode.outputFormat(forBus: 0) == converter.inputFormat {
            do {
                if !engine.isRunning {
                    try engine.start()
                    downlinkPlayer?.resumeAfterEngineRestart()
                }
            } catch {
                trace("local output restart failed: \(error.localizedDescription)")
                pauseForRouteRecovery(reason: reason)
                requestRecovery("本机音频重启失败，正在恢复通话")
                return
            }
            activeRouteSignature = currentRouteSignature
            pendingAudioRouteSelection = nil
            trace("built-in output switched without restarting PCM")
            return
        }
        // A Bluetooth HFP route can be selected by iOS shortly after the audio
        // category changes. It is a supported call route, even while the system
        // reports the built-in microphone as the input. Rebuilding the engine in
        // response causes a category-change / route-reset loop and visible UI
        // stalls. Only stop media when the system has selected an unsupported
        // output (such as the module's USB Audio endpoint), or while a direct
        // user route selection is still pending.
        let requiresImmediatePause = isRunning
            && routeChangeReason != .categoryChange
            && (!routeIsAcceptable || activeRouteSignature != currentRouteSignature)
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
            routeMatchesPolicy: currentRouteIsAcceptableForRecovery,
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
        trace("pausing for route recovery reason=\(reason) route=\(routeSummary)")
        // Recording belongs to the call, not to an audio route. The replacement
        // transport feeds the same recorder so history retains the whole file.
        startGeneration &+= 1
        isRunning = false
        isMediaEnabled = false
        isUplinkEnabled = false
        isDownlinkEnabled = false
        isLocalRingbackEnabled = false
        isTestTone = false
        isAwaitingRecovery = false
        hasActiveRequest = false
        // Keep the active session and selected route while rebuilding the
        // engine. Deactivation itself changes the route and retriggers recovery.
        tearDownAudio(deactivateSession: false, clearOutputOverride: false)
        stateText = "音频路由变化，PCM 已暂停"
        detailText = "等待路由稳定后重新认证 STATUS：\(reason)"
        inputLevel = 0
        downlinkLevel = 0
    }

    private func resetRouteRecoveryTracking() {
        outputSwitchTask?.cancel()
        outputSwitchTask = nil
        isSwitchingBuiltInOutput = false
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
        switch preferredAudioRoute {
        case .receiver:
            return session.currentRoute.inputs.contains { $0.portType == .builtInMic }
                && session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
        case .speaker:
            return session.currentRoute.inputs.contains { $0.portType == .builtInMic }
                && session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        case .accessory(let uid):
            return session.currentRoute.inputs.contains { $0.uid == uid }
                && session.currentRoute.outputs.contains(where: Self.isAccessoryOutput)
        }
    }

    private var currentRouteIsAcceptableForRecovery: Bool {
        if currentRouteMatchesPolicy {
            return true
        }
        // With no unfinished user selection, let iOS keep a valid automatic
        // Bluetooth/headset route rather than forcing an engine restart.
        return pendingAudioRouteSelection == nil && currentRouteUsesSupportedOutput
    }

    private func reconcilePreferredRouteAfterSystemChange(rawReason: UInt) {
        if pendingAudioRouteSelection != nil {
            if currentRouteMatchesPolicy {
                pendingAudioRouteSelection = nil
            }
            return
        }
        guard isRunning,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .override || reason == .categoryChange,
              let route = routeRepresentingCurrentSystemRoute() else { return }
        preferredAudioRoute = route.kind
        selectedAudioRoute = route
        audioRouteErrorText = ""
    }

    private func routeRepresentingCurrentSystemRoute() -> CallAudioRoute? {
        if let input = session.currentRoute.inputs.first(where: {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .headsetMic
        }) {
            let isBluetooth = input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            return CallAudioRoute(
                kind: .accessory(uid: input.uid),
                title: isBluetooth ? "蓝牙：\(input.portName)" : input.portName,
                systemImage: isBluetooth ? "headphones" : "earbuds"
            )
        }
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            return CallAudioRoute(kind: .speaker, title: "扬声器", systemImage: "speaker.wave.2.fill")
        }
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            return CallAudioRoute(kind: .receiver, title: "听筒", systemImage: "phone.fill")
        }
        if let output = session.currentRoute.outputs.first(where: Self.isAccessoryOutput),
           let input = (session.availableInputs ?? []).first(where: {
               $0.portName == output.portName
                   && ($0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .headsetMic)
           }) {
            let isBluetooth = input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            return CallAudioRoute(
                kind: .accessory(uid: input.uid),
                title: isBluetooth ? "蓝牙：\(input.portName)" : input.portName,
                systemImage: isBluetooth ? "headphones" : "earbuds"
            )
        }
        return nil
    }

    private func configureCallAudioSession() throws {
        if session.category != .playAndRecord
            || session.mode != .voiceChat
            || !session.categoryOptions.contains(.allowBluetoothHFP) {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )
        }
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.016)
    }

    private func activatePreferredCallRoute() async throws {
        try configureCallAudioSession()
        try await activateAppAudioSessionIfNeeded()
        try applyPreferredCallRoute()
        guard currentRouteUsesSupportedOutput else { throw CallAudioError.unsupportedOutputSelected }
    }

    private func activateAppAudioSessionIfNeeded() async throws {
        await sessionDeactivationTask?.value
        guard !callKitOwnership.isSystemManaged else { return }
        if #available(iOS 27.0, *) {
            guard try await session.activate(options: []) else {
                throw CallAudioError.audioSessionActivationDeclined
            }
        } else {
            try await Task.detached(priority: .userInitiated) { [session] in
                try session.setActive(true)
            }.value
        }
    }

    private func deactivateAppAudioSessionAfterTeardown() {
        guard !callKitOwnership.isSystemManaged else { return }
        let previous = sessionDeactivationTask
        let generation = startGeneration
        sessionDeactivationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.startGeneration == generation,
                  !self.hasActiveRequest, !self.isRunning else { return }
            try? await self.deactivateAppAudioSession()
        }
    }

    private func deactivateAppAudioSession() async throws {
        guard !callKitOwnership.isSystemManaged else { return }
        if #available(iOS 27.0, *) {
            _ = try await session.deactivate(options: [.notifyOthersOnDeactivation])
        } else {
            try await Task.detached(priority: .utility) { [session] in
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }.value
        }
    }

    private func applyPreferredCallRoute() throws {
        switch preferredAudioRoute {
        case .receiver:
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(try builtInMicrophone())
        case .speaker:
            try session.setPreferredInput(try builtInMicrophone())
            // This is deliberately transient. The user's route choice remains
            // in preferredAudioRoute and is reapplied after an interruption.
            try session.overrideOutputAudioPort(.speaker)
        case .accessory(let uid):
            guard let accessory = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else {
                throw CallAudioError.selectedAccessoryUnavailable
            }
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(accessory)
        }
    }

    private func builtInMicrophone() throws -> AVAudioSessionPortDescription {
        guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw CallAudioError.builtInMicrophoneUnavailable
        }
        return microphone
    }

    private var currentRouteUsesSupportedOutput: Bool {
        session.currentRoute.outputs.contains { output in
            output.portType == .builtInReceiver
                || output.portType == .builtInSpeaker
                || Self.isAccessoryOutput(output)
        }
    }

    private var currentRouteSignature: String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.uid)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.uid)" }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)]"
    }

    private var builtInCallInputUID: String? {
        guard session.currentRoute.outputs.contains(where: {
            $0.portType == .builtInReceiver || $0.portType == .builtInSpeaker
        }) else { return nil }
        return session.currentRoute.inputs.first(where: { $0.portType == .builtInMic })?.uid
    }

    private static func isAccessoryOutput(_ port: AVAudioSessionPortDescription) -> Bool {
        switch port.portType {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .headphones:
            return true
        default:
            return false
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
            await self.retryInterruptedRoute(reason: reason)
        }
    }

    private func retryInterruptedRoute(reason: String) async {
        // Do not compete with CallKit for activation while it owns the call.
        guard !callKitOwnership.isSystemManaged else { return }
        do {
            try? await deactivateAppAudioSession()
            try await activatePreferredCallRoute()
            isInterrupted = false
            cancelInterruptedRouteSettleCheck()
            requestRecovery("蓝牙路由切换已稳定，正在重新确认通话状态（\(reason)）")
        } catch {
            try? await deactivateAppAudioSession()
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
        trace("interruption type=\(type.rawValue) route=\(routeSummary)")

        switch type {
        case .began:
            let shouldRetryAsRouteChange = routeRecoveryState.isRecoveryPending
                || (hasAudioResources && !currentRouteMatchesPolicy)
                || Self.canRetryInterruptionWithoutEnded(notification)
            resetRouteRecoveryTracking()
            isInterrupted = true
            if isRunning || engine != nil || pipeline != nil {
                stopRecording()
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
        stopRecording()
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
        trace("recovery requested reason=\(reason)")
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

    private var routeSummary: String {
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)]"
    }

    private func trace(_ message: String) {
#if DEBUG
        print("DJOneHubAudio \(message)")
#endif
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
        case builtInMicrophoneUnavailable
        case selectedAccessoryUnavailable
        case unsupportedOutputSelected
        case audioSessionActivationDeclined
        case inputFormatUnavailable
        case converterUnavailable
        case prewarmUnavailable
        case outputBufferUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .builtInMicrophoneUnavailable: return "iOS 没有可用的内置麦克风"
            case .selectedAccessoryUnavailable: return "所选耳机已不可用，请重新选择音频设备"
            case .unsupportedOutputSelected: return "iOS 没有切换到受支持的通话输出，已避免将声音送往模块 USB Audio"
            case .audioSessionActivationDeclined: return "iOS 未能激活通话音频"
            case .inputFormatUnavailable: return "无法读取麦克风 PCM 格式"
            case .converterUnavailable: return "无法创建 8 kHz S16_LE 转换器"
            case .prewarmUnavailable: return "模块 PCM 预热资源已失效"
            case .outputBufferUnavailable: return "无法分配 8 kHz PCM 缓冲区"
            case .conversionFailed: return "AVAudioConverter 返回错误"
            }
        }
    }
}
