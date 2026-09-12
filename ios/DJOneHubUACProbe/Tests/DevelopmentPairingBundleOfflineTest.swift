import Foundation

@main
struct DevelopmentPairingBundleOfflineTest {
    static func main() throws {
        let key = Data((0..<32).map(UInt8.init))
        let identifier = DevelopmentPairingBundle.moduleIdentifier(for: key)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid = bundleData(
            key: key,
            identifier: identifier,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
        let decoded = try DevelopmentPairingBundle.decodeAndValidate(valid, now: now)
        precondition(decoded.moduleIdentifier == identifier)
        precondition(decoded.pairingKey == key)
        precondition(decoded.access == .statusOnly)
        precondition(decoded.createdAt == now)
        precondition(decoded.expiresAt == now.addingTimeInterval(3_600))

        let stored = StoredPairingCredential(
            key: decoded.pairingKey,
            access: decoded.access,
            createdAt: decoded.createdAt,
            expiresAt: decoded.expiresAt
        )
        let encodedCredential = try PairingKeyStore.encodeCredential(stored)
        let restored = try PairingKeyStore.decodeCredential(encodedCredential, now: now)
        precondition(restored.key == key)
        precondition(restored.access == .statusOnly)
        precondition(restored.createdAt == now)
        precondition(restored.expiresAt == now.addingTimeInterval(3_600))

        do {
            _ = try PairingKeyStore.decodeCredential(
                encodedCredential,
                now: now.addingTimeInterval(3_601)
            )
            preconditionFailure("expired Keychain credential accepted")
        } catch PairingKeyStoreError.expired {
            // Expected.
        }

        var legacyControlCredential = Data([0x44, 0x4A, 0x50, 0x01, VoiceControlAccess.controlSession.rawValue])
        legacyControlCredential.append(key)
        let restoredLegacy = try PairingKeyStore.decodeCredential(legacyControlCredential, now: now)
        precondition(restoredLegacy.key == key)
        precondition(restoredLegacy.access == .controlSession)
        precondition(restoredLegacy.createdAt == nil)
        precondition(restoredLegacy.expiresAt == nil)

        let control = try DevelopmentPairingBundle.decodeAndValidate(
            bundleData(
                key: key,
                identifier: identifier,
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                purpose: DevelopmentPairingBundle.controlSessionPurpose
            ),
            now: now
        )
        precondition(control.access == .controlSession)

        expect(.identifierMismatch) {
            try DevelopmentPairingBundle.decodeAndValidate(
                bundleData(
                    key: key,
                    identifier: String(repeating: "0", count: 32),
                    createdAt: now.addingTimeInterval(-60),
                    expiresAt: now.addingTimeInterval(3_600)
                ),
                now: now
            )
        }
        expect(.expired) {
            try DevelopmentPairingBundle.decodeAndValidate(
                bundleData(
                    key: key,
                    identifier: identifier,
                    createdAt: now.addingTimeInterval(-3_600),
                    expiresAt: now.addingTimeInterval(-1)
                ),
                now: now
            )
        }
        expect(.createdInFuture) {
            try DevelopmentPairingBundle.decodeAndValidate(
                bundleData(
                    key: key,
                    identifier: identifier,
                    createdAt: now.addingTimeInterval(DevelopmentPairingBundle.maximumClockSkew + 1),
                    expiresAt: now.addingTimeInterval(DevelopmentPairingBundle.maximumClockSkew + 600)
                ),
                now: now
            )
        }
        expect(.validityTooLong) {
            try DevelopmentPairingBundle.decodeAndValidate(
                bundleData(
                    key: key,
                    identifier: identifier,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(DevelopmentPairingBundle.maximumValidity + 1)
                ),
                now: now
            )
        }
        print("DevelopmentPairingBundleOfflineTest: PASS")
    }

    private static func bundleData(
        key: Data,
        identifier: String,
        createdAt: Date,
        expiresAt: Date,
        purpose: String = DevelopmentPairingBundle.statusPurpose
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        return try! JSONSerialization.data(withJSONObject: [
            "version": 1,
            "purpose": purpose,
            "module_identifier": identifier,
            "pairing_key_base64": key.base64EncodedString(),
            "host": DevelopmentPairingBundle.host,
            "port": Int(DevelopmentPairingBundle.port),
            "created_at": formatter.string(from: createdAt),
            "expires_at": formatter.string(from: expiresAt)
        ], options: [.sortedKeys])
    }

    private static func expect(
        _ expected: DevelopmentPairingBundleError,
        operation: () throws -> DevelopmentPairingBundle.Validated
    ) {
        do {
            _ = try operation()
            preconditionFailure("expected \(expected)")
        } catch let error as DevelopmentPairingBundleError {
            precondition(error == expected)
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }
}
