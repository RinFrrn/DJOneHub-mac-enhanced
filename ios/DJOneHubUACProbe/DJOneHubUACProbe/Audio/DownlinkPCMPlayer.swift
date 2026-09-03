import AVFAudio
import Foundation

struct LocalRingbackGenerator {
    static let sampleRate = 8_000
    static let toneSamples = sampleRate
    static let cycleSamples = sampleRate * 5
    static let inBandThreshold: Int32 = 256
    static let inBandHoldoffSamples = sampleRate * 2

    private var sampleIndex = 0
    private var inBandHoldoff = 0

    mutating func reset() {
        sampleIndex = 0
        inBandHoldoff = 0
    }

    mutating func process(_ pcm: Data) -> Data {
        guard pcm.count >= MemoryLayout<Int16>.size, pcm.count.isMultiple(of: 2) else {
            return pcm
        }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        if Self.peak(of: pcm) > Self.inBandThreshold {
            inBandHoldoff = Self.inBandHoldoffSamples
            sampleIndex = 0
            return pcm
        }
        if inBandHoldoff > 0 {
            inBandHoldoff = max(0, inBandHoldoff - sampleCount)
            return pcm
        }

        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in samples.indices {
            let position = sampleIndex % Self.cycleSamples
            if position < Self.toneSamples {
                let phase = 2 * Double.pi * 425 * Double(position) / Double(Self.sampleRate)
                samples[index] = Int16(sin(phase) * 4_096).littleEndian
            }
            sampleIndex = (sampleIndex + 1) % Self.cycleSamples
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func peak(of pcm: Data) -> Int32 {
        pcm.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(into: Int32(0)) { peak, sample in
                peak = max(peak, abs(Int32(Int16(littleEndian: sample))))
            }
        }
    }
}

final class DownlinkPCMPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DJOneHub.DownlinkPCM")
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let onMetrics: @Sendable (DownlinkPlaybackMetrics) -> Void
    private var jitterBuffer = DownlinkJitterBuffer()
    private var metrics = DownlinkPlaybackMetrics()
    private var playoutState = DownlinkPlayoutQueueState()
    private var stopped = false
    private var mediaEnabled: Bool
    private var localRingbackEnabled = false
    private var localRingbackGenerator = LocalRingbackGenerator()

    init(
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        mediaEnabled: Bool = true,
        onMetrics: @escaping @Sendable (DownlinkPlaybackMetrics) -> Void = { _ in }
    ) {
        self.player = player
        self.format = format
        self.mediaEnabled = mediaEnabled
        self.onMetrics = onMetrics
    }

    func enqueue(sequence: UInt32, pcm: Data) {
        queue.async { [self] in
            guard !stopped, mediaEnabled else { return }
            let previousMetrics = metrics
            let playbackPCM = localRingbackEnabled
                ? localRingbackGenerator.process(pcm)
                : pcm
            let result = jitterBuffer.push(sequence: sequence, pcm: playbackPCM)
            metrics.record(result)
            for frame in result.frames {
                scheduleLocked(frame.pcm)
            }
            if metrics != previousMetrics {
                publishMetricsLocked()
            }
        }
    }

    func setMediaEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard !stopped, mediaEnabled != enabled else { return }
            mediaEnabled = enabled
            player.stop()
            jitterBuffer.reset()
            playoutState.reset()
        }
    }

    func setLocalRingbackEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard !stopped, localRingbackEnabled != enabled else { return }
            localRingbackEnabled = enabled
            localRingbackGenerator.reset()
        }
    }

    func enqueueDiagnosticTone() {
        queue.async { [self] in
            guard !stopped, mediaEnabled else { return }
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
                scheduleLocked(samples.withUnsafeBytes { Data($0) }, countQueueDrop: false)
            }
        }
    }

    private func scheduleLocked(_ pcm: Data, countQueueDrop: Bool = true) {
        guard !stopped,
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
        let decision = playoutState.enqueue()
        guard decision != .drop else {
            if countQueueDrop {
                metrics.recordQueueDrop()
            }
            return
        }
        let generation = playoutState.generation
        player.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                if self.playoutState.complete(generation: generation) ==
                    .pauseAndRebuffer {
                    self.player.pause()
                    self.metrics.recordRebuffer()
                    self.publishMetricsLocked()
                }
            }
        }
        if decision == .scheduleAndPlay {
            player.play()
        }
    }

    private func publishMetricsLocked() {
        onMetrics(metrics)
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            player.stop()
            jitterBuffer.reset()
            playoutState.reset()
        }
    }
}
