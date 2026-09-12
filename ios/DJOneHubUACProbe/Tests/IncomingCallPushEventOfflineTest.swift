import Foundation

@main
struct IncomingCallPushEventOfflineTest {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let valid: [AnyHashable: Any] = [
            "v": 1,
            "event": "incoming",
            "call_uuid": uuid.uuidString,
            "module_id": "0123456789abcdef0123456789abcdef",
            "call_id": 7,
            "caller": "+8613800138000",
            "expires_at": now.addingTimeInterval(60).timeIntervalSince1970,
        ]
        let event = try IncomingCallPushEvent(dictionary: valid, now: now)
        precondition(event.kind == .incoming)
        precondition(event.callUUID == uuid)
        precondition(event.moduleCallID == 7)
        precondition(event.callerNumber == "+8613800138000")

        var expired = valid
        expired["expires_at"] = now.addingTimeInterval(-1).timeIntervalSince1970
        expect(.expired) { try IncomingCallPushEvent(dictionary: expired, now: now) }

        var wrongModule = valid
        wrongModule["module_id"] = "not-a-module"
        expect(.invalidPayload) { try IncomingCallPushEvent(dictionary: wrongModule, now: now) }

        var tooFar = valid
        tooFar["expires_at"] = now.addingTimeInterval(301).timeIntervalSince1970
        expect(.expired) { try IncomingCallPushEvent(dictionary: tooFar, now: now) }

        print("IncomingCallPushEventOfflineTest: PASS")
    }

    private static func expect(
        _ expected: IncomingCallPushEventError,
        operation: () throws -> IncomingCallPushEvent
    ) {
        do {
            _ = try operation()
            preconditionFailure("expected \(expected)")
        } catch let error as IncomingCallPushEventError {
            precondition(error == expected)
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }
}
