import Foundation

@MainActor
final class CallLifecycleCoordinator: ObservableObject {
    @Published private(set) var phase: ProductCallPhase = .connecting
    @Published private(set) var hasStarted = false
    @Published private(set) var activeCallDurationSeconds: UInt64 = 0
    @Published private(set) var isMuted = false
    @Published private(set) var endedCallTitle: String?
    @Published private(set) var endedCallNumber: String?
    private var displayedEndedHistoryID: UUID?
    private var endedCallDeadline = ContinuousClock.now
    private var trackedCallID: UInt8?
    private var trackedEventSession: UInt64?
    private var trackedEventBaseline: UInt64 = 0
    private struct EndedHistory {
        let historyID: UUID
        let callID: UInt8
        let session: UInt64
        let baseline: UInt64
        var sequence: UInt64?
    }
    private var endedHistory: [EndedHistory] = []

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
    private var callPresentation = CallPresentationState()

    private let normalStatusPollInterval: Duration = .seconds(1)
    private let setupStatusPollInterval: Duration = .milliseconds(250)

    var shouldPresentCallScreen: Bool { callPresentation.shouldPresentCallScreen }
    var presentedCallPhase: ProductCallPhase? { callPresentation.lastCallPhase }

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
        ConnectionLog.shared.append("开始连接：恢复本机配对配置")
        ConnectionLog.shared.startNetworkMonitoring()
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
        callPresentation.update(with: .connecting)
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
        ConnectionLog.shared.recordNetworkSnapshot()
        nextStatusAttempt = ContinuousClock.now
        if !callAudio.isRunning, !callAudio.hasActiveRequest {
            audioStartRequested = false
            nextAudioStartAttempt = ContinuousClock.now
        }
        updatePhaseAndAudio()
    }

    func dial() {
        endedCallTitle = nil
        endedCallNumber = nil
        displayedEndedHistoryID = nil
        // An unresolved old record must not claim a future reused call ID.
        endedHistory.removeAll { $0.sequence == nil }
        if trackedHistoryID == nil {
            trackedCallID = nil
            trackedEventSession = voiceControl.eventSession
            trackedEventBaseline = voiceControl.endEvents.last?.sequence ?? 0
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

    func beginSystemCallAudio() { callAudio.beginSystemCallAudio() }
    func prepareSystemCallAnswer() throws { try callAudio.prepareSystemCallAnswer() }
    func systemCallAudioDidActivate() {
        callAudio.systemCallAudioDidActivate()
        audioStartRequested = false
        nextStatusAttempt = .now
        nextAudioStartAttempt = .now
        updatePhaseAndAudio()
    }
    func systemCallAudioDidDeactivate() {
        callAudio.systemCallAudioDidDeactivate()
        audioStartRequested = false
    }
    func endSystemCallAudio() {
        callAudio.endSystemCallAudio()
        audioStartRequested = false
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
            nextStatusAttempt = clock.now.advanced(by: .milliseconds(750))
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
        callPresentation.update(with: derivedPhase)
        synchronizeCallHistory(with: derivedPhase)
        if phase != derivedPhase {
            ConnectionLog.shared.append("连接状态：\(derivedPhase.title)")
#if DEBUG
            print("DJOneHubLifecycle phase \(String(describing: phase)) -> \(String(describing: derivedPhase))")
#endif
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
            guard !callAudio.isInterrupted, callAudio.canStartSystemCallAudio else {
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
                      let key = voiceControl.sessionKeyForModuleServices() else { return }
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
        if endedCallTitle != nil, ContinuousClock.now >= endedCallDeadline {
            endedCallTitle = nil
            endedCallNumber = nil
        }
        for index in endedHistory.indices {
            guard endedHistory[index].session == voiceControl.eventSession else { continue }
            let record = endedHistory[index]
            let event = voiceControl.endEvents.first {
                $0.callID == record.callID &&
                (record.sequence == nil ? $0.sequence > record.baseline : $0.sequence == record.sequence)
            }
            if let event {
                endedHistory[index].sequence = event.sequence
                history.updateEndReason(event.rawReason, for: record.historyID)
                if endedCallTitle != nil, displayedEndedHistoryID == record.historyID {
                    endedCallTitle = event.title
                }
            }
        }
        if trackedHistoryID == nil,
           let callID = derivedPhase.callID,
           let call = voiceControl.calls.first(where: { $0.id == callID }) {
            endedHistory.removeAll { $0.callID == callID && $0.sequence == nil }
            let direction: CallHistoryDirection = call.direction == 2 ? .incoming : .outgoing
            trackedDirection = direction
            trackedHistoryID = history.begin(
                direction: direction,
                number: direction == .incoming ? call.presentedRemoteNumber : nil
            )
            trackedWasConnected = false
            trackedUserEnded = false
            trackedCallID = callID
            trackedEventSession = voiceControl.eventSession
            trackedEventBaseline = voiceControl.endEvents.last?.sequence ?? 0
        }

        if trackedHistoryID != nil, let id = derivedPhase.callID {
            trackedCallID = id
        }
        if trackedHistoryID != nil, trackedDirection == .outgoing, trackedCallID == nil {
            trackedCallID = voiceControl.lastDialCallID
        }
        if trackedHistoryID != nil, trackedEventSession == nil {
            trackedEventSession = voiceControl.eventSession
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
        if let id = trackedCallID, let session = trackedEventSession,
           session == voiceControl.eventSession {
            let event = voiceControl.endEvents.first {
                $0.callID == id && $0.sequence > trackedEventBaseline
            }
            if let event { history.updateEndReason(event.rawReason, for: trackedHistoryID) }
            endedHistory.append(EndedHistory(historyID: trackedHistoryID, callID: id,
                session: session, baseline: trackedEventBaseline, sequence: event?.sequence))
            if endedHistory.count > 16 { endedHistory.removeFirst() }
            if !trackedUserEnded, trackedDirection == .outgoing, !trackedWasConnected {
                endedCallTitle = event?.title ?? "呼叫已结束"
                displayedEndedHistoryID = trackedHistoryID
                endedCallNumber = history.entries.first { $0.id == trackedHistoryID }?.number
                endedCallDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            }
        }
        self.trackedHistoryID = nil
        self.trackedDirection = nil
        trackedWasConnected = false
        trackedUserEnded = false
        trackedCallID = nil
        trackedEventSession = nil
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
              callAudio.canStartSystemCallAudio,
              mediaRecoveryGate.isOpen,
              !callAudio.isInterrupted,
              !callAudio.isRunning,
              !callAudio.hasActiveRequest,
              ContinuousClock.now >= nextAudioStartAttempt,
              let key = voiceControl.sessionKeyForModuleServices() else { return }
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
