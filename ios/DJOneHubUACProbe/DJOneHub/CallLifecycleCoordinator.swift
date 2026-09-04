import Foundation

@MainActor
final class CallLifecycleCoordinator: ObservableObject {
    @Published private(set) var phase: ProductCallPhase = .connecting
    @Published private(set) var hasStarted = false
    @Published private(set) var activeCallDurationSeconds: UInt64 = 0
    @Published private(set) var isMuted = false

    private let voiceControl: VoiceControlModel
    private let callAudio: CallAudioCoordinator
    private let history: CallHistoryStore
    private var lifecycleTask: Task<Void, Never>?
    private var audioStartRequested = false
    private var handledAudioRecoveryGeneration: UInt64
    private var mediaRecoveryGate = StatusConfirmedMediaRecoveryGate()
    private var callDurationTracker = ActiveCallDurationTracker()
    private var nextStatusAttempt = ContinuousClock.now
    private var nextAudioStartAttempt = ContinuousClock.now
    private var trackedHistoryID: UUID?
    private var trackedDirection: CallHistoryDirection?
    private var trackedWasConnected = false
    private var trackedUserEnded = false

    private let normalStatusPollInterval: Duration = .seconds(1)
    private let setupStatusPollInterval: Duration = .milliseconds(250)

    init(
        voiceControl: VoiceControlModel,
        callAudio: CallAudioCoordinator,
        history: CallHistoryStore
    ) {
        self.voiceControl = voiceControl
        self.callAudio = callAudio
        self.history = history
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
        callDurationTracker.reset()
        activeCallDurationSeconds = 0
        isMuted = false
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
        if trackedHistoryID == nil {
            trackedDirection = .outgoing
            trackedHistoryID = history.begin(
                direction: .outgoing,
                number: voiceControl.dialNumber
            )
            trackedWasConnected = false
            trackedUserEnded = false
        }
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
        trackedUserEnded = true
        nextStatusAttempt = .now
        voiceControl.end(callID: callID)
        updatePhaseAndAudio()
    }

    func toggleMute() {
        guard case .active = phase else { return }
        isMuted.toggle()
        updatePhaseAndAudio()
    }

    func attachRecording(_ url: URL) {
        guard let trackedHistoryID else { return }
        history.attachRecording(filename: url.lastPathComponent, to: trackedHistoryID)
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
        let derivedPhase = ProductCallPhase.derive(
            isConfigured: voiceControl.isConfigured,
            canControlCalls: voiceControl.canControlCalls,
            isBusy: voiceControl.isBusy,
            shouldPollStatus: voiceControl.shouldPollStatus,
            calls: voiceControl.calls,
            stateText: voiceControl.stateText
        )
        synchronizeCallHistory(with: derivedPhase)
        if phase != derivedPhase {
            phase = derivedPhase
        }
        let durationSeconds = callDurationTracker.update(
            phase: derivedPhase,
            now: ContinuousClock.now
        )
        if activeCallDurationSeconds != durationSeconds {
            activeCallDurationSeconds = durationSeconds
        }

        let shouldPrepareAudio = voiceControl.canControlCalls && derivedPhase.shouldPrepareCallAudio
        let shouldEnableUplink = voiceControl.canControlCalls
            && derivedPhase.shouldEnableUplink
            && !isMuted
        let shouldEnableDownlink = voiceControl.canControlCalls && derivedPhase.shouldEnableDownlink
        let shouldGenerateLocalRingback = voiceControl.canControlCalls
            && derivedPhase.shouldGenerateLocalRingback(calls: voiceControl.calls)
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
                switch derivedPhase {
                case .connecting, .recovering:
                    reason = "控制链路中断，本地 PCM 已停止；重新认证 STATUS 并确认仍在通话后才会恢复"
                default:
                    reason = nil
                }
                callAudio.stop(reason: reason)
            }
        }
    }

    private func synchronizeCallHistory(with derivedPhase: ProductCallPhase) {
        if trackedHistoryID == nil,
           let callID = derivedPhase.callID,
           let call = voiceControl.calls.first(where: { $0.id == callID }) {
            let direction: CallHistoryDirection = call.direction == 2 ? .incoming : .outgoing
            trackedDirection = direction
            trackedHistoryID = history.begin(direction: direction, number: nil)
            trackedWasConnected = false
            trackedUserEnded = false
        }

        if case .active = derivedPhase,
           let trackedHistoryID,
           !trackedWasConnected {
            trackedWasConnected = true
            history.markConnected(trackedHistoryID)
        }

        guard case .ready = derivedPhase,
              let trackedHistoryID,
              let trackedDirection else { return }
        let outcome: CallHistoryOutcome
        if trackedWasConnected {
            outcome = .completed
        } else if trackedDirection == .incoming {
            outcome = trackedUserEnded ? .rejected : .missed
        } else {
            outcome = trackedUserEnded ? .canceled : .failed
        }
        history.finish(trackedHistoryID, outcome: outcome)
        self.trackedHistoryID = nil
        self.trackedDirection = nil
        trackedWasConnected = false
        trackedUserEnded = false
        isMuted = false
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
