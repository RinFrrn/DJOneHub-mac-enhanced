import Foundation
import CryptoKit
import Testing
@testable import ModuleAuthorization

private func invitation(purpose: String = "module-recovery", expires: Int64? = nil) throws -> ModuleInvitation {
    ModuleInvitation(version: 1, purpose: purpose, moduleID: String(repeating: "a", count: 32),
                     host: ModuleIdentity.host, port: ModuleIdentity.port,
                     certificateSHA256: String(repeating: "b", count: 64),
                     secret: try AuthorizationSecret.generate(), expiresAt: expires)
}

@Test func secretsAreCanonicalAndIndependent() throws {
    let first = try AuthorizationSecret.generate()
    let second = try AuthorizationSecret.generate()
    #expect(first != second)
    #expect(AuthorizationSecret.isValid(first))
    #expect(!AuthorizationSecret.isValid(first + "="))
    #expect(!AuthorizationSecret.isValid(String(repeating: "!", count: 43)))
    #expect(!AuthorizationSecret.isValid(String(repeating: "A", count: 42) + "B"))
}

@Test func recoverySurvivesTimeAndDevelopmentBundlesAreRejected() throws {
    let recovery = try invitation()
    let data = try JSONEncoder().encode(recovery)
    let restored = try ModuleInvitation.decode(data, now: Date(timeIntervalSince1970: 5_000_000_000))
    #expect(restored.identity == recovery.identity)
    #expect(throws: (any Error).self) {
        try ModuleInvitation.decode(Data(#"{"version":1,"purpose":"development-control-session"}"#.utf8))
    }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(throws: ModuleAuthorizationError.self) { try invitation(purpose: "module-bootstrap", expires: 2_000_000_000).validate(now: now) }
    #expect(throws: ModuleAuthorizationError.self) { try invitation(purpose: "module-bootstrap", expires: 2_000_086_400).validate(now: now) }
    try invitation(purpose: "module-bootstrap", expires: 2_000_000_900).validate(now: now)
}

@Test func identityPinDoesNotTrustAnotherCertificate() throws {
    let bytes = Data("test certificate DER".utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let identity = ModuleIdentity(moduleID: String(repeating: "a", count: 32), certificateSHA256: digest)
    try identity.validate()
    #expect(identity.verifies(certificate: bytes))
    #expect(!identity.verifies(certificate: Data("another certificate".utf8)))
}

@Test func pendingAndActiveCredentialsRoundTripWithoutExpiry() throws {
    let source = try invitation()
    let active = ModuleAuthorizationRecord.Active(credential: try AuthorizationSecret.generate(), deviceID: try AuthorizationSecret.generate())
    let pending = ModuleAuthorizationRecord.Pending(
        invitation: source, credential: try AuthorizationSecret.generate(), name: "我的新 iPhone",
        newRecoverySecret: try AuthorizationSecret.generate(), prepared: nil, backupConfirmed: false
    )
    let record = ModuleAuthorizationRecord(version: 1, identity: source.identity, active: active, pending: pending)
    try record.validate()
    let decoded = try JSONDecoder().decode(ModuleAuthorizationRecord.self, from: JSONEncoder().encode(record))
    try decoded.validate()
    #expect(decoded.active?.credential == active.credential)
    #expect(decoded.pending?.credential == pending.credential)
    #expect(decoded.pending?.backupConfirmed == false)
}

@Test func corruptPendingEnrollmentIsRejected() throws {
    let source = try invitation()
    let pending = ModuleAuthorizationRecord.Pending(
        invitation: source, credential: source.secret, name: "phone",
        newRecoverySecret: nil, prepared: nil, backupConfirmed: false
    )
    let record = ModuleAuthorizationRecord(version: 1, identity: source.identity, active: nil, pending: pending)
    #expect(throws: ModuleAuthorizationError.self) { try record.validate() }
}

@Test func parsesBoundedHTTPResponse() throws {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
    let decoded = try ModuleAuthorizationTransport.decodeHTTP(response)
    #expect(decoded.status == 200)
    #expect(decoded.body == Data("{}".utf8))
}

@Test(arguments: [
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}extra",
    "HTTP/1.1 200 OK\r\n\r\n{}"
]) func rejectsAmbiguousHTTP(response: String) {
    #expect(throws: ModuleAuthorizationError.self) { try ModuleAuthorizationTransport.decodeHTTP(Data(response.utf8)) }
}
