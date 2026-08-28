import AVFAudio
import Foundation
import Network

struct AudioRouteItem: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let uid: String
    let channelCount: Int
}

@MainActor
final class AudioProbeModel: ObservableObject {
    @Published private(set) var currentInputs: [AudioRouteItem] = []
    @Published private(set) var currentOutputs: [AudioRouteItem] = []
    @Published private(set) var availableInputs: [AudioRouteItem] = []
    @Published private(set) var inputAvailable = false
    @Published private(set) var sampleRateText = "—"
    @Published private(set) var ioBufferText = "—"
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var meterText = "停止"
    @Published private(set) var isSessionActive = false
    @Published private(set) var isRouteStable = false
    @Published private(set) var isMetering = false
    @Published private(set) var isForwardingUplink = false
    @Published private(set) var isForwardingDownlink = false
    @Published private(set) var logText = ""

    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var hasInputTap = false
    private var observers: [NSObjectProtocol] = []
    private var logLines: [String] = []
    private var routeSettleTask: Task<Void, Never>?
    private var routeRevision = 0

    var isUSBInput: Bool {
        session.currentRoute.inputs.contains { $0.portType == .usbAudio }
    }

    var isUSBOutput: Bool {
        session.currentRoute.outputs.contains { $0.portType == .usbAudio }
    }

    var isBidirectionalUSB: Bool {
        isUSBInput && isUSBOutput
    }

    var isBuiltInMicInput: Bool {
        session.currentRoute.inputs.contains { $0.portType == .builtInMic }
    }

    var isBuiltInSpeakerOutput: Bool {
        session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    var isUsefulProbeRoute: Bool {
        isBidirectionalUSB || (isBuiltInMicInput && isUSBOutput) || (isUSBInput && isBuiltInSpeakerOutput)
    }

    var verdict: String {
        if isUSBInput && isBuiltInSpeakerOutput {
            return "下行组合成立：模块 USB 输入 + iPhone 扬声器"
        }
        if isBuiltInMicInput && isUSBOutput {
            return "上行组合成立：iPhone 麦克风 + 模块 USB 输出"
        }
        if isBidirectionalUSB {
            return "模块已枚举为双向 USB Audio（仍需拆向验证）"
        }
        if isUSBInput {
            return "只检测到 USB 输入，输出未落在模块"
        }
        if isUSBOutput {
            return "只检测到 USB 输出，输入未落在模块"
        }
        return "当前路由不是模块 USB Audio"
    }

    init() {
        engine.attach(player)
        registerNotifications()
        refresh(reason: "app launched")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func activateAndPreferUSB() {
        requestPermissionAndActivate(preferredPort: .usbAudio, label: "USB input")
    }

    func activateAndPreferBuiltInMic() {
        requestPermissionAndActivate(preferredPort: .builtInMic, label: "built-in microphone")
    }

    func activateUSBInputAndSpeaker() {
        requestPermissionAndActivate(preferredPort: .usbAudio, label: "USB input", forceSpeaker: true)
    }

    private func requestPermissionAndActivate(
        preferredPort: AVAudioSession.Port,
        label: String,
        forceSpeaker: Bool = false
    ) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.appendLog("microphone permission denied")
                    self.refresh(reason: "permission denied")
                    return
                }
                self.activateSession(preferredPort: preferredPort, label: label, forceSpeaker: forceSpeaker)
            }
        }
    }

    func refresh(reason: String) {
        let route = session.currentRoute
        currentInputs = route.inputs.map(Self.routeItem)
        currentOutputs = route.outputs.map(Self.routeItem)
        availableInputs = (session.availableInputs ?? []).map(Self.routeItem)
        inputAvailable = session.isInputAvailable
        sampleRateText = String(format: "%.0f Hz", session.sampleRate)
        ioBufferText = String(format: "%.2f ms", session.ioBufferDuration * 1_000)
        appendLog("\(reason): \(routeSummary(route))")
    }

    func toggleMeter() {
        isMetering ? stopMeter() : startMeter()
    }

    func playTestTone() {
        guard isSessionActive, isRouteStable, isUSBOutput else {
            appendLog("test tone refused: current output is not USB Audio")
            return
        }

        do {
            rebuildEngine()

            let sampleRate = max(session.sampleRate, 8_000)
            let frameCount = AVAudioFrameCount(sampleRate * 0.5)
            guard
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                let channel = buffer.floatChannelData?[0]
            else {
                appendLog("test tone failed: cannot allocate PCM buffer")
                return
            }

            buffer.frameLength = frameCount
            let peak = pow(10.0, -24.0 / 20.0)
            let fadeFrames = max(1, Int(sampleRate * 0.01))
            for frame in 0 ..< Int(frameCount) {
                let fadeIn = min(1.0, Double(frame) / Double(fadeFrames))
                let fadeOut = min(1.0, Double(Int(frameCount) - frame - 1) / Double(fadeFrames))
                let envelope = min(fadeIn, fadeOut)
                channel[frame] = Float(sin(2.0 * .pi * 700.0 * Double(frame) / sampleRate) * peak * envelope)
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)
            try startEngine(context: "test tone output")
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [])
            player.play()
            appendLog("test tone scheduled: 700 Hz, 500 ms, -24 dBFS, \(Int(sampleRate)) Hz")
        } catch {
            appendLog("test tone failed: \(error.localizedDescription)")
        }
    }

    func toggleUplinkForwarding() {
        if isForwardingUplink {
            stopEngineForReconfiguration()
            appendLog("built-in microphone uplink stopped")
            return
        }

        guard isSessionActive, isBuiltInMicInput, isUSBOutput else {
            appendLog("microphone uplink refused: requires builtInMic input and USB Audio output")
            return
        }
        guard isRouteStable else {
            appendLog("microphone uplink refused: audio route is still settling")
            return
        }

        do {
            rebuildEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }
            appendLog("uplink input format: \(Self.formatSummary(inputFormat))")
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
            installMeterTap(on: input)
            try startEngine(context: "microphone uplink")
            isForwardingUplink = true
            isMetering = true
            meterText = "上行中"
            appendLog("built-in microphone forwarding started -> USB Audio output")
        } catch {
            stopEngineForReconfiguration()
            appendLog("microphone uplink failed: \(error.localizedDescription)")
        }
    }

    func toggleDownlinkForwarding() {
        if isForwardingDownlink {
            stopEngineForReconfiguration()
            appendLog("USB downlink to built-in speaker stopped")
            return
        }

        guard isSessionActive, isUSBInput, isBuiltInSpeakerOutput else {
            appendLog("speaker downlink refused: requires USB Audio input and built-in speaker output")
            return
        }
        guard isRouteStable else {
            appendLog("speaker downlink refused: audio route is still settling")
            return
        }

        do {
            rebuildEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }
            appendLog("downlink input format: \(Self.formatSummary(inputFormat))")
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
            installMeterTap(on: input)
            try startEngine(context: "USB downlink to built-in speaker")
            isForwardingDownlink = true
            isMetering = true
            meterText = "下行中"
            appendLog("USB Audio input forwarding started -> built-in speaker")
        } catch {
            stopEngineForReconfiguration()
            appendLog("speaker downlink failed: \(error.localizedDescription)")
        }
    }

    func clearLog() {
        logLines.removeAll()
        logText = ""
    }

    private func activateSession(
        preferredPort: AVAudioSession.Port,
        label: String,
        forceSpeaker: Bool
    ) {
        do {
            markRouteUnstable()
            stopEngineForReconfiguration()
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
            try session.overrideOutputAudioPort(.none)
            isSessionActive = true
            appendLog("audio session activated: playAndRecord/default")

            let preferredInput = session.availableInputs?.first { $0.portType == preferredPort }
            if let preferredInput {
                try session.setPreferredInput(preferredInput)
                appendLog("preferred \(label): \(preferredInput.portName) [\(preferredInput.uid)]")
            } else {
                appendLog("no \(label) in availableInputs")
            }

            if forceSpeaker {
                try session.overrideOutputAudioPort(.speaker)
                appendLog("requested built-in speaker output override")
            }

            refresh(reason: "session activated")
            scheduleRouteStabilityCheck()
        } catch {
            isSessionActive = false
            isRouteStable = false
            appendLog("session activation failed: \(error.localizedDescription)")
            refresh(reason: "activation error")
        }
    }

    private func startMeter() {
        guard isSessionActive else {
            appendLog("input meter refused: session is inactive")
            return
        }

        do {
            guard isRouteStable else {
                appendLog("input meter refused: audio route is still settling")
                return
            }
            rebuildEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }
            appendLog("meter input format: \(Self.formatSummary(inputFormat))")
            installMeterTap(on: input)
            try startEngine(context: "input meter")
            isMetering = true
            meterText = "监听中"
            appendLog("input meter started")
        } catch {
            appendLog("input meter failed: \(error.localizedDescription)")
            stopMeter()
        }
    }

    private func stopMeter() {
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        isMetering = false
        inputLevel = 0
        meterText = "停止"
        appendLog("input meter stopped")
    }

    private func installMeterTap(on input: AVAudioInputNode) {
        guard !hasInputTap else { return }

        input.installTap(onBus: 0, bufferSize: 256, format: nil) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }

            var squareSum: Float = 0
            for channel in 0 ..< channels {
                for frame in 0 ..< frames {
                    let sample = samples[channel][frame]
                    squareSum += sample * sample
                }
            }
            let rms = sqrt(squareSum / Float(frames * channels))
            let decibels = max(-80, 20 * log10(max(rms, 0.0001)))
            let normalized = Double((decibels + 80) / 80)

            Task { @MainActor [weak self] in
                self?.inputLevel = normalized
                self?.meterText = String(format: "%.1f dBFS", decibels)
            }
        }
        hasInputTap = true
    }

    private func startEngine(context: String) throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
        appendLog("audio engine started (\(context))")
    }

    private func registerNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.markRouteUnstable()
                self.stopEngineForReconfiguration()
                self.refresh(reason: "route changed (\(Self.routeReason(rawReason)))")
                self.scheduleRouteStabilityCheck()
            }
        })

        if #available(iOS 26.0, *) {
            observers.append(center.addObserver(forName: AVAudioSession.availableInputsChangeNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markRouteUnstable()
                    self.refresh(reason: "available inputs changed")
                    self.scheduleRouteStabilityCheck()
                }
            })
        }

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.markRouteUnstable()
                self.stopEngineForReconfiguration()
                self.appendLog("audio interruption: \(rawType == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended")")
                self.refresh(reason: "interruption")
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSessionActive = false
                self.markRouteUnstable()
                self.stopEngineForReconfiguration()
                self.refresh(reason: "media services reset")
            }
        })
    }

    private func stopEngineForReconfiguration() {
        player.stop()
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        engine.stop()
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeOutput(player)
        engine.reset()
        isMetering = false
        isForwardingUplink = false
        isForwardingDownlink = false
        inputLevel = 0
        meterText = "停止"
    }

    private func rebuildEngine() {
        stopEngineForReconfiguration()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        appendLog("audio engine rebuilt for settled route")
    }

    private func markRouteUnstable() {
        routeRevision &+= 1
        routeSettleTask?.cancel()
        routeSettleTask = nil
        isRouteStable = false
    }

    private func scheduleRouteStabilityCheck() {
        let revision = routeRevision
        routeSettleTask?.cancel()
        routeSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.routeRevision == revision else { return }
            self.isRouteStable = true
            self.appendLog("audio route stable for 500 ms")
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logLines.append("\(formatter.string(from: Date()))  \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
        logText = logLines.joined(separator: "\n")
    }

    private func routeSummary(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "in=[\(inputs)] out=[\(outputs)] rate=\(Int(session.sampleRate))Hz buffer=\(String(format: "%.2f", session.ioBufferDuration * 1_000))ms"
    }

    private static func routeItem(_ port: AVAudioSessionPortDescription) -> AudioRouteItem {
        AudioRouteItem(
            id: "\(port.portType.rawValue)|\(port.uid)",
            name: port.portName,
            type: port.portType.rawValue,
            uid: port.uid,
            channelCount: port.channels?.count ?? 0
        )
    }

    private static func formatSummary(_ format: AVAudioFormat) -> String {
        let description = format.streamDescription.pointee
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, format=0x\(String(description.mFormatID, radix: 16)), flags=0x\(String(description.mFormatFlags, radix: 16)), interleaved=\(format.isInterleaved)"
    }

    private static func routeReason(_ rawValue: UInt) -> String {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else {
            return "unknown:\(rawValue)"
        }
        switch reason {
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        @unknown default: return "future:\(rawValue)"
        }
    }
}

@MainActor
final class ModuleNetworkProbe: ObservableObject {
    @Published private(set) var pathText = "检测中"
    @Published private(set) var stateText = "未测试"
    @Published private(set) var detailText = ""
    @Published private(set) var latencyText = "—"
    @Published private(set) var isTesting = false

    let host = "192.168.225.1"
    let port: UInt16 = 45_750

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "DJOneHubUACProbe.network-path")
    private var connection: NWConnection?

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let interface = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }).map { String(describing: $0.type) }
                ?? path.availableInterfaces.first.map { String(describing: $0.type) }
                ?? "无接口"
            Task { @MainActor in
                guard let self else { return }
                self.pathText = path.status == .satisfied ? "可用 · \(interface)" : "不可用 · \(path.status.description)"
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
        connection?.cancel()
    }

    func probeControlPort() {
        connection?.cancel()
        connection = nil
        isTesting = true
        stateText = "连接中"
        detailText = "正在探测 \(host):\(port)"
        latencyText = "—"

        let started = Date()
        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isTesting = false
                    self.stateText = "控制端口可达"
                    self.latencyText = String(format: "%.0f ms", Date().timeIntervalSince(started) * 1_000)
                    self.detailText = "TCP \(self.host):\(self.port) 已建立；模块 daemon 已监听"
                    connection?.cancel()
                case .failed(let error):
                    self.isTesting = false
                    self.latencyText = String(format: "%.0f ms", Date().timeIntervalSince(started) * 1_000)
                    if case let .posix(code) = error, code == .ECONNREFUSED {
                        self.stateText = "网络可达，端口未监听"
                        self.detailText = "模块已响应 TCP 拒绝；下一步需要部署 djonehubd 控制 daemon"
                    } else {
                        self.stateText = "控制端口不可达"
                        self.detailText = Self.errorText(error)
                    }
                case .cancelled:
                    if self.isTesting {
                        self.isTesting = false
                        self.stateText = "探测已取消"
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "DJOneHubUACProbe.network-connection"))
    }

    private static func errorText(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue)：\(code)"
        case .dns(let code):
            return "DNS \(code)"
        case .tls(let code):
            return "TLS \(code)"
        default:
            return error.localizedDescription
        }
    }
}

private extension NWPath.Status {
    var description: String {
        switch self {
        case .satisfied: return "已连接"
        case .unsatisfied: return "无网络"
        case .requiresConnection: return "等待连接"
        @unknown default: return "未知"
        }
    }
}

private enum ProbeError: LocalizedError {
    case inputFormatUnavailable
    case outputFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .inputFormatUnavailable:
            return "input hardware format has zero sample rate or zero channels"
        case .outputFormatUnavailable:
            return "cannot create the mono output format"
        }
    }
}
