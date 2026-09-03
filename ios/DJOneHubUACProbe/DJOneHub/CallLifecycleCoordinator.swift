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

    private let normalStatusPollInterval: Duration = .seconds(1)
    private let setupStatusPollInterval: Duration = .milliseconds(250)

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
                try? await Task.sleep(for: .milliseconds(250))
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

    func dial() {
        prepareAudioForUserAction()
        nextStatusAttempt = .now
        voiceControl.dial()
        updatePhaseAndAudio()
    }

    func answer(callID: UInt8) {
        prepareAudioForUserAction()
        nextStatusAttempt = .now
        voiceControl.answer(callID: callID)
        updatePhaseAndAudio()
    }

    func end(callID: UInt8) {
        nextStatusAttempt = .now
        voiceControl.end(callID: callID)
        updatePhaseAndAudio()
    }

    private func tick(clock: ContinuousClock) {
        updatePhaseAndAudio()

        guard voiceControl.isConfigured, voiceControl.canControlCalls else { return }
        guard !voiceControl.isBusy else { return }

        if voiceControl.shouldPollStatus, clock.now >= nextStatusAttempt {
            voiceControl.pollStatus()
            let interval = phase.prefersFastStatusPolling
                ? setupStatusPollInterval
                : normalStatusPollInterval
            nextStatusAttempt = clock.now.advanced(by: interval)
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

        let shouldPrepareAudio = voiceControl.canControlCalls && phase.shouldPrepareCallAudio
        let shouldEnableMedia = voiceControl.canControlCalls && phase.shouldEnableCallMedia
        if handledAudioRecoveryGeneration != callAudio.recoveryGeneration {
            handledAudioRecoveryGeneration = callAudio.recoveryGeneration
            audioStartRequested = false
        }
        if shouldPrepareAudio {
            guard !callAudio.isInterrupted else {
                audioStartRequested = false
                return
            }
            if callAudio.isRunning || callAudio.hasActiveRequest {
                callAudio.setMediaEnabled(shouldEnableMedia)
            } else {
                guard !audioStartRequested,
                      let key = voiceControl.pairingKeyForUplinkProbe() else { return }
                audioStartRequested = true
                callAudio.start(pairingKey: key, mediaEnabled: shouldEnableMedia)
            }
        } else {
            audioStartRequested = false
            if callAudio.isRunning || callAudio.hasActiveRequest {
                callAudio.stop()
            }
        }
    }

    private func prepareAudioForUserAction() {
        guard voiceControl.canControlCalls,
              !callAudio.isInterrupted,
              !callAudio.isRunning,
              !callAudio.hasActiveRequest,
              let key = voiceControl.pairingKeyForUplinkProbe() else { return }
        audioStartRequested = true
        callAudio.start(pairingKey: key, mediaEnabled: false)
    }

}
