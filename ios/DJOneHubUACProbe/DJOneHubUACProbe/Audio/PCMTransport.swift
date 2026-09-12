import Foundation
import Network

final class PCMTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DJOneHub.PCMTransport")
    private let pairingKey: Data
    private let sessionID: UInt32
    private let onState: @Sendable (String) -> Void
    private let onProgress: @Sendable (UInt64, Double) -> Void
    private let onUplinkFrame: @Sendable (Data) -> Void
    private let onDownlink: @Sendable (UInt32, Data, UInt64) -> Void
    private let onError: @Sendable (String) -> Void
    private var connection: NWConnection?
    private var toneTimer: DispatchSourceTimer?
    private var warmupTimer: DispatchSourceTimer?
    private var toneSampleIndex: UInt64 = 0
    private var pendingPCM = Data()
    private var sequence: UInt32 = 0
    private var frames: UInt64 = 0
    private var downlinkFrames: UInt64 = 0
    private var stopped = false
    private var connectionReady = false
    private var mediaEnabled: Bool

    init(
        pairingKey: Data,
        sessionID: UInt32,
        mediaEnabled: Bool = true,
        onState: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (UInt64, Double) -> Void,
        onUplinkFrame: @escaping @Sendable (Data) -> Void = { _ in },
        onDownlink: @escaping @Sendable (UInt32, Data, UInt64) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.pairingKey = pairingKey
        self.sessionID = sessionID
        self.mediaEnabled = mediaEnabled
        self.onState = onState
        self.onProgress = onProgress
        self.onUplinkFrame = onUplinkFrame
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
                        self.connectionReady = true
                        self.onState("双向 PCM 传输中")
                        self.receiveDownlinkLocked(connection)
                        self.updateWarmupTimerLocked()
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
            guard !stopped, mediaEnabled else { return }
            pendingPCM.append(pcm)
            while pendingPCM.count >= UplinkAudioProtocol.pcmBytes {
                let frame = Data(pendingPCM.prefix(UplinkAudioProtocol.pcmBytes))
                pendingPCM.removeFirst(UplinkAudioProtocol.pcmBytes)
                if sendFrameLocked(frame) {
                    frames &+= 1
                    onUplinkFrame(frame)
                }
            }
            onProgress(frames, peak)
        }
    }

    func setMediaEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard !stopped, mediaEnabled != enabled else { return }
            mediaEnabled = enabled
            pendingPCM.removeAll(keepingCapacity: true)
            updateWarmupTimerLocked()
        }
    }

    private func updateWarmupTimerLocked() {
        if stopped || mediaEnabled || !connectionReady {
            warmupTimer?.cancel()
            warmupTimer = nil
            return
        }
        guard warmupTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.mediaEnabled else { return }
            _ = self.sendFrameLocked(Data(repeating: 0, count: UplinkAudioProtocol.pcmBytes))
        }
        warmupTimer = timer
        timer.resume()
    }

    @discardableResult
    private func sendFrameLocked(_ frame: Data) -> Bool {
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
            return true
        } catch {
            failLocked(error.localizedDescription)
            return false
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
            warmupTimer?.cancel()
            warmupTimer = nil
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
        warmupTimer?.cancel()
        warmupTimer = nil
        connection?.cancel()
        connection = nil
        pendingPCM.removeAll(keepingCapacity: false)
        onError(message)
    }
}
