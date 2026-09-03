import Foundation

@MainActor
final class CallLifecycleCoordinator: ObservableObject {
    @Published private(set) var phase: ProductCallPhase = .connecting
    @Published private(set) var hasStarted = false

    private let voiceControl: VoiceControlModel
    private let callAudio: CallAudioCoordinator
    private var lifecycleTask: Task<Void, Never>?
    private var audioStartRequested = false
    private var handledAudioRecoveryGeneration: UInt64
    private var nextStatusAttempt = ContinuousClock.now

    init(voiceControl: VoiceControlModel, callAudio: CallAudioCoordinator) {
        self.voiceControl = voiceControl
        self.callAudio = callAudio
        handledAudioRecoveryGeneration = callAudio.recoveryGeneration
    }

    deinit {
        lifecycleTask?.cancel()
    }

    func start() {
        guard lifecycleTask == nil else { return }
        voiceControl.restorePairings()
        hasStarted = true
        updatePhaseAndAudio()
        lifecycleTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(clock: clock)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        audioStartRequested = false
        if callAudio.isRunning || callAudio.hasActiveRequest {
            callAudio.stop()
        }
        hasStarted = false
    }

    func pairingDidChange() {
        nextStatusAttempt = ContinuousClock.now
        audioStartRequested = false
        updatePhaseAndAudio()
    }

    private func tick(clock: ContinuousClock) {
        updatePhaseAndAudio()

        guard voiceControl.isConfigured, voiceControl.canControlCalls else { return }
        guard !voiceControl.isBusy else { return }

        if voiceControl.shouldPollStatus, clock.now >= nextStatusAttempt {
            voiceControl.pollStatus()
            nextStatusAttempt = clock.now.advanced(by: .seconds(1))
        } else if clock.now >= nextStatusAttempt {
            voiceControl.refreshStatus()
            nextStatusAttempt = clock.now.advanced(by: .seconds(3))
        }
    }

    private func updatePhaseAndAudio() {
        phase = ProductCallPhase.derive(
            isConfigured: voiceControl.isConfigured,
            canControlCalls: voiceControl.canControlCalls,
            isBusy: voiceControl.isBusy,
            shouldPollStatus: voiceControl.shouldPollStatus,
            calls: voiceControl.calls,
            stateText: voiceControl.stateText
        )

        let shouldRunAudio = voiceControl.canControlCalls && voiceControl.hasActiveCall
        if handledAudioRecoveryGeneration != callAudio.recoveryGeneration {
            handledAudioRecoveryGeneration = callAudio.recoveryGeneration
            audioStartRequested = false
        }
        if shouldRunAudio {
            guard !callAudio.isInterrupted else {
                audioStartRequested = false
                return
            }
            guard !callAudio.isRunning, !audioStartRequested,
                  let key = voiceControl.pairingKeyForUplinkProbe() else { return }
            audioStartRequested = true
            callAudio.start(pairingKey: key)
        } else {
            audioStartRequested = false
            if callAudio.isRunning || callAudio.hasActiveRequest {
                callAudio.stop()
            }
        }
    }

}
