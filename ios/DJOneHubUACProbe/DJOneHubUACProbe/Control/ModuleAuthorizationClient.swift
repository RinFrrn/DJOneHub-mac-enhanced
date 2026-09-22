import Foundation
import Network
import Security

struct ModuleAuthorizationTransport: Sendable {
    let identity: ModuleIdentity

    func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ operation: String, credential: String, body: Body, response: Response.Type
    ) async throws -> Response {
        try identity.validate()
        guard ["prepare", "commit", "status", "session", "revoke", "cancel"].contains(operation),
              AuthorizationSecret.isValid(credential) else { throw ModuleAuthorizationError.invalidData }
        let payload = try JSONEncoder().encode(body)
        guard payload.count <= 4096 else { throw ModuleAuthorizationError.invalidData }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let identity = identity
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  chain.count == 1, let certificate = chain.first else { complete(false); return }
            // This exact certificate pin came from the trusted first-install or
            // recovery artifact. Never accept a new pin learned over this link.
            complete(identity.verifies(certificate: SecCertificateCopyData(certificate) as Data))
        }, DispatchQueue(label: "DJOneHub.ModuleAuthorization.Trust"))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .wiredEthernet
        guard let port = NWEndpoint.Port(rawValue: ModuleIdentity.port) else { throw ModuleAuthorizationError.invalidData }
        let connection = NWConnection(host: NWEndpoint.Host(ModuleIdentity.host), port: port, using: parameters)
        defer { connection.cancel() }
        var wire = Data(("POST /v1/\(operation) HTTP/1.1\r\nHost: \(ModuleIdentity.host):\(ModuleIdentity.port)\r\n" +
            "Authorization: Bearer \(credential)\r\nContent-Type: application/json\r\n" +
            "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n").utf8)
        wire.append(payload)
        let requestData = wire
        let received = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await connection.authorizationStart()
                    try await connection.authorizationSend(requestData)
                    return try await connection.authorizationReceive()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    connection.cancel()
                    throw ModuleAuthorizationError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ModuleAuthorizationError.connectionFailed }
                return result
            }
        } onCancel: { connection.cancel() }
        let decoded = try Self.decodeHTTP(received)
        guard decoded.status == 200 else {
            let error = try? JSONDecoder().decode(RemoteAuthorizationError.self, from: decoded.body)
            switch error?.error {
            case "unauthorized": throw ModuleAuthorizationError.unauthorized
            case "change_pending": throw ModuleAuthorizationError.pendingChange
            case "device_limit": throw ModuleAuthorizationError.deviceLimit
            case "storage_unavailable": throw ModuleAuthorizationError.storageUnavailable
            default: throw ModuleAuthorizationError.invalidData
            }
        }
        return try JSONDecoder().decode(Response.self, from: decoded.body)
    }

    static func decodeHTTP(_ data: Data) throws -> (status: Int, body: Data) {
        guard data.count <= 16_384,
              let split = data.range(of: Data("\r\n\r\n".utf8)), split.lowerBound <= 4096,
              let header = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            throw ModuleAuthorizationError.invalidData
        }
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0] == "HTTP/1.1",
              let status = Int(statusLine[1]), (200...599).contains(status) else { throw ModuleAuthorizationError.invalidData }
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ModuleAuthorizationError.invalidData }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { throw ModuleAuthorizationError.invalidData }
            if name == "content-length" {
                guard contentLength == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let size = Int(value), size <= 12_288 else { throw ModuleAuthorizationError.invalidData }
                contentLength = size
            }
        }
        let body = Data(data[split.upperBound...])
        guard let contentLength, body.count == contentLength else { throw ModuleAuthorizationError.invalidData }
        return (status, body)
    }
}

private struct EmptyAuthorizationRequest: Codable, Sendable {}
private struct RemoteAuthorizationError: Decodable { let error: String }
private struct RevokeAuthorizationRequest: Encodable, Sendable {
    let deviceID: String
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

// The wizard can use this model without ever touching legacy PairingKeyStore.
// Saving a pending enrollment precedes every request which could activate it.
@MainActor
final class ModuleAuthorizationModel {
    private let store = ModuleAuthorizationStore()
    private var isBusy = false

    func savedModuleIDs() throws -> [String] { try store.moduleIDs() }

    func begin(invitation: ModuleInvitation, name: String) throws {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        try invitation.validate()
        var record = try store.load(moduleID: invitation.moduleID) ?? ModuleAuthorizationRecord(
            version: 1, identity: invitation.identity, active: nil, pending: nil
        )
        guard record.identity == invitation.identity else { throw ModuleAuthorizationError.identityMismatch }
        guard record.pending == nil else { throw ModuleAuthorizationError.pendingChange }
        record.pending = ModuleAuthorizationRecord.Pending(
            invitation: invitation, credential: try AuthorizationSecret.generate(), name: name,
            newRecoverySecret: invitation.purpose == "module-recovery" ? try AuthorizationSecret.generate() : nil,
            prepared: nil, backupConfirmed: false
        )
        try store.save(record)
    }

    func prepare(moduleID: String) async throws -> PreparedModuleAuthorization {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        isBusy = true
        defer { isBusy = false }
        guard var record = try store.load(moduleID: moduleID), var pending = record.pending else {
            throw ModuleAuthorizationError.noPendingEnrollment
        }
        let request = PrepareModuleAuthorization(
            kind: pending.invitation.purpose == "module-recovery" ? "recovery" : "bootstrap",
            credential: pending.credential, name: pending.name, newRecoverySecret: pending.newRecoverySecret
        )
        let prepared = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "prepare", credential: pending.invitation.secret, body: request, response: PreparedModuleAuthorization.self
        )
        guard prepared.moduleID == moduleID else { throw ModuleAuthorizationError.identityMismatch }
        pending.prepared = prepared
        record.pending = pending
        try store.save(record)
        return prepared
    }

    // Explicit export for the recovery-backup UI; never placed in diagnostics.
    func replacementRecoveryInvitation(moduleID: String) throws -> ModuleInvitation? {
        guard let pending = try store.load(moduleID: moduleID)?.pending,
              let secret = pending.newRecoverySecret else { return nil }
        return pending.invitation.replacingRecoverySecret(secret)
    }

    func confirmRecoveryBackup(moduleID: String) throws {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        guard var record = try store.load(moduleID: moduleID), record.pending != nil else {
            throw ModuleAuthorizationError.noPendingEnrollment
        }
        record.pending?.backupConfirmed = true
        try store.save(record)
    }

    func commit(moduleID: String) async throws -> ModuleAuthorizationStatus {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        isBusy = true
        defer { isBusy = false }
        guard var record = try store.load(moduleID: moduleID), let pending = record.pending,
              let prepared = pending.prepared else { throw ModuleAuthorizationError.noPendingEnrollment }
        guard pending.backupConfirmed else { throw ModuleAuthorizationError.backupRequired }
        let result = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "commit", credential: pending.credential, body: EmptyAuthorizationRequest(), response: ModuleAuthorizationStatus.self
        )
        try validate(result, identity: record.identity)
        guard result.currentDeviceID == prepared.deviceID,
              result.devices.contains(where: { $0.id == prepared.deviceID }) else { throw ModuleAuthorizationError.identityMismatch }
        record.active = .init(credential: pending.credential, deviceID: prepared.deviceID)
        record.pending = nil
        // If this local save fails, the persisted pending secret can retry commit.
        try store.save(record)
        return result
    }

    func status(moduleID: String) async throws -> ModuleAuthorizationStatus {
        guard let record = try store.load(moduleID: moduleID), let active = record.active else {
            throw ModuleAuthorizationError.unauthorized
        }
        let status = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "status", credential: active.credential, body: EmptyAuthorizationRequest(), response: ModuleAuthorizationStatus.self
        )
        try validate(status, identity: record.identity)
        guard status.currentDeviceID == active.deviceID,
              status.devices.contains(where: { $0.id == active.deviceID }) else { throw ModuleAuthorizationError.identityMismatch }
        return status
    }

    func voiceSession(moduleID: String) async throws -> ModuleVoiceSession {
        guard let record = try store.load(moduleID: moduleID), let active = record.active else {
            throw ModuleAuthorizationError.unauthorized
        }
        let session = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "session", credential: active.credential, body: EmptyAuthorizationRequest(), response: ModuleVoiceSession.self
        )
        guard session.version == 1, session.scope == "voice-control",
              session.expiresAt > 0,
              AuthorizationSecret.isValid(session.credential) else { throw ModuleAuthorizationError.invalidData }
        return session
    }

    func cancelPending(moduleID: String) async throws {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        isBusy = true
        defer { isBusy = false }
        guard var record = try store.load(moduleID: moduleID), let pending = record.pending else {
            throw ModuleAuthorizationError.noPendingEnrollment
        }
        _ = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "cancel", credential: pending.credential, body: EmptyAuthorizationRequest(), response: EmptyAuthorizationRequest.self
        )
        record.pending = nil
        if record.active != nil { try store.save(record) }
        else { try store.forgetLocal(moduleID: moduleID) }
    }

    func revoke(moduleID: String, deviceID: String) async throws -> ModuleAuthorizationStatus {
        guard !isBusy else { throw ModuleAuthorizationError.pendingChange }
        isBusy = true
        defer { isBusy = false }
        guard let record = try store.load(moduleID: moduleID), let active = record.active,
              AuthorizationSecret.isValid(deviceID) else { throw ModuleAuthorizationError.unauthorized }
        guard deviceID != active.deviceID || record.pending == nil else { throw ModuleAuthorizationError.pendingChange }
        let result = try await ModuleAuthorizationTransport(identity: record.identity).request(
            "revoke", credential: active.credential, body: RevokeAuthorizationRequest(deviceID: deviceID),
            response: ModuleAuthorizationStatus.self
        )
        try validate(result, identity: record.identity)
        guard !result.devices.contains(where: { $0.id == deviceID }) else { throw ModuleAuthorizationError.invalidData }
        // Keep local evidence after an ambiguous response. Only confirmed remote
        // self-revocation permits deleting this phone's stored credentials.
        if deviceID == active.deviceID { try store.forgetLocal(moduleID: moduleID) }
        return result
    }

    private func validate(_ status: ModuleAuthorizationStatus, identity: ModuleIdentity) throws {
        guard status.version == 1, status.moduleID == identity.moduleID, status.generation > 0,
              status.devices.count <= 4, AuthorizationSecret.isValid(status.currentDeviceID),
              Set(status.devices.map(\.id)).count == status.devices.count,
              status.devices.allSatisfy({ AuthorizationSecret.isValid($0.id) }) else {
            throw ModuleAuthorizationError.identityMismatch
        }
    }
}

private extension NWConnection {
    func authorizationStart() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = AuthorizationConnectionGate(continuation)
            stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(.success(()))
                case .failed: gate.resume(.failure(ModuleAuthorizationError.connectionFailed))
                case .cancelled: gate.resume(.failure(CancellationError()))
                default: break
                }
            }
            start(queue: DispatchQueue(label: "DJOneHub.ModuleAuthorization.Connection"))
        }
    }

    func authorizationSend(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: ModuleAuthorizationError.connectionFailed) }
                else { continuation.resume() }
            })
        }
    }

    func authorizationReceive() async throws -> Data {
        var result = Data()
        while true {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Bool), Error>) in
                receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    if error != nil { continuation.resume(throwing: ModuleAuthorizationError.connectionFailed) }
                    else { continuation.resume(returning: (data ?? Data(), complete)) }
                }
            }
            result.append(chunk.0)
            guard result.count <= 16_384 else { throw ModuleAuthorizationError.invalidData }
            if chunk.1 { return result }
            guard !chunk.0.isEmpty else { throw ModuleAuthorizationError.connectionFailed }
        }
    }
}

private final class AuthorizationConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
