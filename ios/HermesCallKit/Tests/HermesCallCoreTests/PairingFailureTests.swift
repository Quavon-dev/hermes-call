import Foundation
import Testing
@testable import HermesCallCore

struct PairingFailureTests {
    @Test func relayAnswersBecomeDistinctFailures() {
        #expect(PairingFailure.classify(ProtocolError.relay("rate_limited")) == .rateLimited)
        #expect(PairingFailure.classify(ProtocolError.relay("busy")) == .relayBusy)
        #expect(PairingFailure.classify(ProtocolError.relay("pairing_failed")) == .wrongOrExpiredCode)
        #expect(PairingFailure.classify(ProtocolError.pairingFailed) == .wrongOrExpiredCode)
        #expect(PairingFailure.classify(ProtocolError.cryptoFailure) == .wrongOrExpiredCode)
        #expect(PairingFailure.classify(ProtocolError.pinMismatch) == .tlsMismatch)
        #expect(PairingFailure.classify(ProtocolError.invalidCode) == .invalidInput)
        #expect(PairingFailure.classify(ProtocolError.timeout) == .unreachable)
        #expect(PairingFailure.classify(ProtocolError.unexpected("?")) == .other)
    }

    @Test func networkErrorsBecomeUnreachableOrTLS() {
        #expect(PairingFailure.classify(URLError(.cannotFindHost)) == .unreachable)
        #expect(PairingFailure.classify(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(PairingFailure.classify(URLError(.timedOut)) == .unreachable)
        #expect(PairingFailure.classify(URLError(.serverCertificateUntrusted)) == .tlsMismatch)
        #expect(PairingFailure.classify(URLError(.secureConnectionFailed)) == .tlsMismatch)
        #expect(PairingFailure.classify(URLError(.badURL)) == .other)
    }

    /// The relay's rate limit and connection cap answer the WebSocket upgrade with plain HTTP.
    @Test func upgradeStatusesAndPinMismatchAreRecognised() {
        #expect(RelayTrust.openError(status: 429, pinMismatch: false, error: URLError(.badServerResponse)) as? ProtocolError
            == .relay("rate_limited"))
        #expect(RelayTrust.openError(status: 503, pinMismatch: false, error: nil) as? ProtocolError == .relay("busy"))
        #expect(RelayTrust.openError(status: nil, pinMismatch: true, error: URLError(.cancelled)) as? ProtocolError == .pinMismatch)
        #expect((RelayTrust.openError(status: 200, pinMismatch: false, error: URLError(.networkConnectionLost)) as? URLError)?.code
            == .networkConnectionLost)
    }
}

struct PhoneWriteTests {
    let now = Date()

    func query(_ capability: PhoneCapability, _ params: [String: JSON]) -> PhoneQuery? {
        PhoneQuery.parse(["type": "phone_query", "query_id": .string(Base64URL.encode(Data(repeating: 3, count: 16))),
                          "capability": .string(capability.rawValue), "reason": "Add it",
                          "expires": .int(Int64((now.timeIntervalSince1970 + 60) * 1000)), "params": .object(params)], now: now)
    }

    @Test func remindersNeedATitleAndAValidDueDate() {
        let item = query(.reminderCreate, ["title": "  Call the plumber ", "due": "2026-10-01T09:00:00Z", "notes": "Leak"])?.newItem
        #expect(item?.title == "Call the plumber" && item?.notes == "Leak")
        #expect(item?.due == Date(timeIntervalSince1970: 1_790_845_200))
        #expect(query(.reminderCreate, ["title": "No due date"])?.newItem?.due == nil)
        #expect(query(.reminderCreate, ["title": "x", "due": "tomorrow"])?.newItem == nil)
        #expect(query(.reminderCreate, ["title": ""])?.newItem == nil)
        #expect(query(.reminderCreate, ["title": .string(String(repeating: "a", count: 201))])?.newItem == nil)
    }

    @Test func eventsNeedAStartBeforeTheirEnd() {
        let event = query(.calendarCreate, ["title": "Dentist", "start": "2026-10-02T15:00:00+02:00",
                                            "end": "2026-10-02T15:45:00+02:00", "location": "Main St 1"])?.newItem
        #expect(event?.start != nil && event?.location == "Main St 1")
        #expect(query(.calendarCreate, ["title": "Backwards", "start": "2026-10-02T15:00:00Z", "end": "2026-10-02T14:00:00Z"])?.newItem == nil)
        #expect(query(.calendarCreate, ["title": "Too long", "start": "2026-10-01T00:00:00Z", "end": "2026-10-20T00:00:00Z"])?.newItem == nil)
        #expect(query(.calendarCreate, ["title": "No end", "start": "2026-10-02T15:00:00Z"])?.newItem == nil)
    }

    @Test func writeCapabilitiesAreNoByDefaultAndMayBeYes() throws {
        let settings = PhoneAccessSettings(defaults: try #require(UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)")))
        for capability in [PhoneCapability.reminderCreate, .calendarCreate] {
            #expect(capability.writes)
            #expect(settings.permission(for: capability) == .no)
            settings.set(.yes, for: capability)
            #expect(settings.permission(for: capability) == .yes)
        }
        #expect(!PhoneCapability.calendar.writes)
        #expect(PhoneCapability(rawValue: "reminder_create") == .reminderCreate)
    }
}
