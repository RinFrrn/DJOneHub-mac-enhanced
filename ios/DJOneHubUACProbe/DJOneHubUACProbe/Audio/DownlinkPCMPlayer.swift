import AVFAudio
import Foundation

final class DownlinkPCMPlayer: @unchecked Sendable {
    private static let startupFrameCount = 4
    private static let maximumBufferedFrameCount = 16

    private let queue = DispatchQueue(label: "DJOneHub.DownlinkPCM")
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let onMetrics: @Sendable (DownlinkPlaybackMetrics) -> Void
    private var jitterBuffer = DownlinkJitterBuffer()
    private var metrics = DownlinkPlaybackMetrics()
    private var bufferedFrames = 0
    private var started = false
    private var stopped = false
    private var mediaEnabled: Bool

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
            let result = jitterBuffer.push(sequence: sequence, pcm: pcm)
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
            bufferedFrames = 0
            started = false
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
        guard bufferedFrames < Self.maximumBufferedFrameCount else {
            if countQueueDrop {
                metrics.recordQueueDrop()
            }
            return
        }
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
                    self.metrics.recordRebuffer()
                    self.publishMetricsLocked()
                }
            }
        }
        if !started, bufferedFrames >= Self.startupFrameCount {
            player.play()
            started = true
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
            bufferedFrames = 0
            started = false
        }
    }
}
