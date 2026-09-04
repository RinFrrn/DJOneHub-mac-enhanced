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
    private var mediaRecoveryGate = StatusConfirmedMediaRecoveryGate()
    private var nextStatusAttempt = ContinuousClock.now
    private var nextAudioStartAttempt = ContinuousClock.now

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
        mediaRecoveryGate.reset()
        if callAudio.isRunning || callAudio.hasActiveRequest || callAudio.isAwaitingRecovery {
            callAudio.stop()
        }
        hasStarted = false
    }

    func pairingDidChange() {
        nextStatusAttempt = ContinuousClock.now
        nextAudioStartAttempt = ContinuousClock.now
        audioStartRequested = false
        mediaRecoveryGate.reset()
        updatePhaseAndAudio()
    }

    func applicationDidBecomeActive() {
        nextStatusAttempt = ContinuousClock.now
        if !callAudio.isRunning, !callAudio.hasActiveRequest {
            audioStartRequested = false
            nextAudioStartAttempt = ContinuousClock.now
        }
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
        let shouldEnableUplink = voiceControl.canControlCalls && phase.shouldEnableUplink
        let shouldEnableDownlink = voiceControl.canControlCalls && phase.shouldEnableDownlink
        let shouldGenerateLocalRingback = voiceControl.canControlCalls
            && phase.shouldGenerateLocalRingback(calls: voiceControl.calls)
        synchronizeMediaRecoveryGate()
        if voiceControl.shouldPollStatus {
            callAudio.markControlRecoveredIfNeeded()
        }
        if shouldPrepareAudio {
            guard !callAudio.isInterrupted else {
                audioStartRequested = false
                return
            }
            if callAudio.isRunning || callAudio.hasActiveRequest {
                callAudio.setMediaEnabled(
                    uplink: shouldEnableUplink,
                    downlink: shouldEnableDownlink,
                    localRingback: shouldGenerateLocalRingback
                )
            } else {
                guard !audioStartRequested,
                      mediaRecoveryGate.isOpen,
                      ContinuousClock.now >= nextAudioStartAttempt,
                      let key = voiceControl.pairingKeyForUplinkProbe() else { return }
                audioStartRequested = true
                nextAudioStartAttempt = ContinuousClock.now.advanced(by: .seconds(1))
                callAudio.start(
                    pairingKey: key,
                    uplinkEnabled: shouldEnableUplink,
                    downlinkEnabled: shouldEnableDownlink,
                    localRingbackEnabled: shouldGenerateLocalRingback
                )
            }
        } else {
            audioStartRequested = false
            nextAudioStartAttempt = ContinuousClock.now
            if callAudio.isRunning || callAudio.hasActiveRequest || callAudio.isAwaitingRecovery {
                let reason: String?
                switch phase {
                case .connecting, .recovering:
                    reason = "控制链路中断，本地 PCM 已停止；重新认证 STATUS 并确认仍在通话后才会恢复"
                default:
                    reason = nil
                }
                callAudio.stop(reason: reason)
            }
        }
    }

    private func synchronizeMediaRecoveryGate() {
        if handledAudioRecoveryGeneration != callAudio.recoveryGeneration {
            handledAudioRecoveryGeneration = callAudio.recoveryGeneration
            audioStartRequested = false
            mediaRecoveryGate.requireNewStatus(after: voiceControl.statusSuccessGeneration)
            nextStatusAttempt = .now
        }
        mediaRecoveryGate.observeControlState(
            isStatusPollingHealthy: voiceControl.shouldPollStatus,
            statusGeneration: voiceControl.statusSuccessGeneration
        )
    }

    private func prepareAudioForUserAction() {
        synchronizeMediaRecoveryGate()
        guard voiceControl.canControlCalls,
              mediaRecoveryGate.isOpen,
              !callAudio.isInterrupted,
              !callAudio.isRunning,
              !callAudio.hasActiveRequest,
              ContinuousClock.now >= nextAudioStartAttempt,
              let key = voiceControl.pairingKeyForUplinkProbe() else { return }
        audioStartRequested = true
        nextAudioStartAttempt = ContinuousClock.now.advanced(by: .seconds(1))
        callAudio.start(
            pairingKey: key,
            uplinkEnabled: false,
            downlinkEnabled: false,
            localRingbackEnabled: false
        )
    }

}
