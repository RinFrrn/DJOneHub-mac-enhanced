import AVFAudio
import CallKit
import Foundation
import PushKit

@MainActor
final class SystemCallCoordinator: NSObject, ObservableObject {
    @Published private(set) var pushStateText = "PushKit 尚未启动"
    @Published private(set) var hasVoIPToken = false
    @Published private(set) var isCallKitAudioActive = false

    private let voiceControl: VoiceControlModel
    private let lifecycle: CallLifecycleCoordinator
    private let provider: CXProvider
    private let callController = CXCallController()
    private var pushRegistry: PKPushRegistry?
    private var callIDByUUID: [UUID: UInt8] = [:]
    private var uuidByCallID: [UInt8: UUID] = [:]
    private var callerByCallID: [UInt8: String] = [:]
    private var presentationByCallID: [UInt8: UInt8] = [:]
    private var confirmedUUIDs: Set<UUID> = []
    private var answeredUUIDs: Set<UUID> = []
    private var locallyEndedCallIDs: Set<UInt8> = []
    private var confirmationTimeouts: [UUID: Task<Void, Never>] = [:]

    init(voiceControl: VoiceControlModel, lifecycle: CallLifecycleCoordinator) {
        self.voiceControl = voiceControl
        self.lifecycle = lifecycle

        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)

        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit {
        confirmationTimeouts.values.forEach { $0.cancel() }
    }

    func start() {
        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
        pushStateText = "等待 APNs VoIP token"
    }

    func synchronize(with phase: ProductCallPhase) {
        switch phase {
        case .incoming(let callID):
            let call = voiceControl.calls.first { $0.id == callID }
            ensureIncomingCall(
                callID: callID,
                caller: callerByCallID[callID] ?? call?.presentedRemoteNumber,
                presentation: call?.remoteNumberPresentation,
                confirmed: true
            )
        case .answering(let callID), .active(let callID):
            guard let uuid = uuidByCallID[callID] else { return }
            confirm(uuid)
            if case .active = phase { answeredUUIDs.insert(uuid) }
        case .ready:
            let completedCalls = callIDByUUID.filter { confirmedUUIDs.contains($0.key) }
            for (uuid, callID) in completedCalls {
                let reason: CXCallEndedReason = answeredUUIDs.contains(uuid) ? .remoteEnded : .unanswered
                endReportedCall(uuid: uuid, reason: reason)
                locallyEndedCallIDs.remove(callID)
            }
            locallyEndedCallIDs.removeAll()
        default:
            break
        }
    }

    func requestAnswer(callID: UInt8) {
        guard let uuid = uuidByCallID[callID] else {
            lifecycle.answer(callID: callID)
            return
        }
        let transaction = CXTransaction(action: CXAnswerCallAction(call: uuid))
        callController.request(transaction) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.lifecycle.answer(callID: callID) }
        }
    }

    func requestEnd(callID: UInt8) {
        guard let uuid = uuidByCallID[callID] else {
            lifecycle.end(callID: callID)
            return
        }
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        callController.request(transaction) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.lifecycle.end(callID: callID) }
        }
    }

    private func handle(_ event: IncomingCallPushEvent, completion: @escaping () -> Void) {
        if voiceControl.moduleIdentifier == nil {
            voiceControl.restorePairings()
        }
        guard event.moduleIdentifier == voiceControl.moduleIdentifier?.lowercased() else {
            pushStateText = "忽略了不属于当前模块的 VoIP Push"
            completion()
            return
        }

        switch event.kind {
        case .incoming:
            callerByCallID[event.moduleCallID] = event.callerNumber
            lifecycle.start()
            lifecycle.applicationDidBecomeActive()
            ensureIncomingCall(
                uuid: event.callUUID,
                callID: event.moduleCallID,
                caller: event.callerNumber,
                presentation: event.callerNumber == nil ? nil : 0,
                confirmed: false,
                completion: completion
            )
        case .ended:
            endReportedCall(uuid: event.callUUID, reason: .remoteEnded)
            completion()
        }
    }

    private func ensureIncomingCall(
        uuid: UUID? = nil,
        callID: UInt8,
        caller: String?,
        presentation: UInt8? = nil,
        confirmed: Bool,
        completion: (() -> Void)? = nil
    ) {
        if locallyEndedCallIDs.contains(callID) {
            completion?()
            return
        }
        if let existing = uuidByCallID[callID] {
            let callerChanged = caller != nil && callerByCallID[callID] != caller
            let presentationChanged = presentation != nil
                && presentationByCallID[callID] != presentation
            if callerChanged || presentationChanged {
                if let caller { callerByCallID[callID] = caller }
                if let presentation { presentationByCallID[callID] = presentation }
                provider.reportCall(
                    with: existing,
                    updated: makeCallUpdate(caller: caller, presentation: presentation)
                )
            }
            if confirmed { confirm(existing) }
            completion?()
            return
        }

        let callUUID = uuid ?? UUID()
        lifecycle.beginSystemCallAudio()
        callIDByUUID[callUUID] = callID
        uuidByCallID[callID] = callUUID
        if let caller { callerByCallID[callID] = caller }
        if let presentation { presentationByCallID[callID] = presentation }
        if confirmed { confirm(callUUID) }

        let update = makeCallUpdate(caller: caller, presentation: presentation)
        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else {
                    completion?()
                    return
                }
                if let error {
                    self.pushStateText = "CallKit 来电上报失败：\(error.localizedDescription)"
                    self.removeMapping(uuid: callUUID)
                } else {
                    self.pushStateText = "CallKit 已接收来电"
                    if !confirmed { self.scheduleConfirmationTimeout(for: callUUID) }
                }
                completion?()
            }
        }
    }

    private func makeCallUpdate(caller: String?, presentation: UInt8?) -> CXCallUpdate {
        let update = CXCallUpdate()
        if let caller, !caller.isEmpty {
            update.remoteHandle = CXHandle(type: .phoneNumber, value: caller)
            update.localizedCallerName = caller
        } else {
            update.remoteHandle = CXHandle(type: .generic, value: "DJOneHub")
            update.localizedCallerName = presentation == 1 ? "私人号码" : "未知号码"
        }
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsHolding = false
        update.supportsUngrouping = false
        return update
    }

    private func confirm(_ uuid: UUID) {
        confirmedUUIDs.insert(uuid)
        confirmationTimeouts.removeValue(forKey: uuid)?.cancel()
    }

    private func scheduleConfirmationTimeout(for uuid: UUID) {
        confirmationTimeouts[uuid]?.cancel()
        confirmationTimeouts[uuid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.confirmedUUIDs.contains(uuid) else { return }
            self.pushStateText = "模块未确认来电，已关闭 CallKit 界面"
            self.endReportedCall(uuid: uuid, reason: .failed)
        }
    }

    private func endReportedCall(uuid: UUID, reason: CXCallEndedReason) {
        guard callIDByUUID[uuid] != nil else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        removeMapping(uuid: uuid)
    }

    private func removeMapping(uuid: UUID) {
        confirmationTimeouts.removeValue(forKey: uuid)?.cancel()
        confirmedUUIDs.remove(uuid)
        answeredUUIDs.remove(uuid)
        guard let callID = callIDByUUID.removeValue(forKey: uuid) else { return }
        uuidByCallID.removeValue(forKey: callID)
        callerByCallID.removeValue(forKey: callID)
        presentationByCallID.removeValue(forKey: callID)
        if callIDByUUID.isEmpty { lifecycle.endSystemCallAudio() }
    }
}

extension SystemCallCoordinator: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        hasVoIPToken = !pushCredentials.token.isEmpty
        pushStateText = hasVoIPToken
            ? "VoIP Push token 已就绪，等待接入 Relay"
            : "APNs 返回了空的 VoIP Push token"
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        hasVoIPToken = false
        pushStateText = "VoIP Push token 已失效"
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        do {
            let event = try IncomingCallPushEvent(dictionary: payload.dictionaryPayload)
            handle(event, completion: completion)
        } catch {
            pushStateText = "VoIP Push 内容无效或已经过期"
            completion()
        }
    }
}

extension SystemCallCoordinator: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let callID = lifecycle.phase.callID {
            lifecycle.end(callID: callID)
        }
        confirmationTimeouts.values.forEach { $0.cancel() }
        confirmationTimeouts.removeAll()
        callIDByUUID.removeAll()
        uuidByCallID.removeAll()
        callerByCallID.removeAll()
        presentationByCallID.removeAll()
        confirmedUUIDs.removeAll()
        answeredUUIDs.removeAll()
        locallyEndedCallIDs.removeAll()
        isCallKitAudioActive = false
        lifecycle.endSystemCallAudio()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callID = callIDByUUID[action.callUUID] else {
            action.fail()
            return
        }
        do {
            try lifecycle.prepareSystemCallAnswer()
        } catch {
            pushStateText = "无法配置系统通话音频：\(error.localizedDescription)"
            action.fail()
            return
        }
        answeredUUIDs.insert(action.callUUID)
        confirm(action.callUUID)
        lifecycle.answer(callID: callID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callID = callIDByUUID[action.callUUID] else {
            action.fail()
            return
        }
        locallyEndedCallIDs.insert(callID)
        lifecycle.end(callID: callID)
        removeMapping(uuid: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        isCallKitAudioActive = true
        lifecycle.systemCallAudioDidActivate()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        isCallKitAudioActive = false
        lifecycle.systemCallAudioDidDeactivate()
    }
}
