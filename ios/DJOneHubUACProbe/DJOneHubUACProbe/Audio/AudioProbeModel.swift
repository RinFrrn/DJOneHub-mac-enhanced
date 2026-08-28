import AVFAudio
import Foundation

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
    @Published private(set) var isMetering = false
    @Published private(set) var isForwardingUplink = false
    @Published private(set) var logText = ""

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var hasInputTap = false
    private var observers: [NSObjectProtocol] = []
    private var logLines: [String] = []

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

    var verdict: String {
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

    private func requestPermissionAndActivate(preferredPort: AVAudioSession.Port, label: String) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.appendLog("microphone permission denied")
                    self.refresh(reason: "permission denied")
                    return
                }
                self.activateSession(preferredPort: preferredPort, label: label)
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
        guard isSessionActive, isUSBOutput else {
            appendLog("test tone refused: current output is not USB Audio")
            return
        }

        do {
            try ensureEngineRunning()

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

        do {
            stopEngineForReconfiguration()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
            try ensureEngineRunning()
            isForwardingUplink = true
            isMetering = true
            meterText = "上行中"
            appendLog("built-in microphone forwarding started -> USB Audio output")
        } catch {
            stopEngineForReconfiguration()
            appendLog("microphone uplink failed: \(error.localizedDescription)")
        }
    }

    func clearLog() {
        logLines.removeAll()
        logText = ""
    }

    private func activateSession(preferredPort: AVAudioSession.Port, label: String) {
        do {
            stopEngineForReconfiguration()
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
            isSessionActive = true
            appendLog("audio session activated: playAndRecord/default")

            let preferredInput = session.availableInputs?.first { $0.portType == preferredPort }
            if let preferredInput {
                try session.setPreferredInput(preferredInput)
                appendLog("preferred \(label): \(preferredInput.portName) [\(preferredInput.uid)]")
            } else {
                appendLog("no \(label) in availableInputs")
            }

            refresh(reason: "session activated")
        } catch {
            isSessionActive = false
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
            try ensureEngineRunning()
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

    private func ensureEngineRunning() throws {
        if !hasInputTap {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw ProbeError.inputFormatUnavailable
            }

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

        if !engine.isRunning {
            guard let toneFormat = AVAudioFormat(
                standardFormatWithSampleRate: max(session.sampleRate, 8_000),
                channels: 1
            ) else {
                throw ProbeError.outputFormatUnavailable
            }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
            engine.prepare()
            try engine.start()
            appendLog("audio engine started")
        }
    }

    private func registerNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopEngineForReconfiguration()
                self.refresh(reason: "route changed (\(Self.routeReason(rawReason)))")
            }
        })

        if #available(iOS 26.0, *) {
            observers.append(center.addObserver(forName: AVAudioSession.availableInputsChangeNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh(reason: "available inputs changed")
                }
            })
        }

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopEngineForReconfiguration()
                self.appendLog("audio interruption: \(rawType == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended")")
                self.refresh(reason: "interruption")
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSessionActive = false
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
        engine.reset()
        isMetering = false
        isForwardingUplink = false
        inputLevel = 0
        meterText = "停止"
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
