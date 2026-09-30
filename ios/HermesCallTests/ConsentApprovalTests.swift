import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// Face ID / passcode stand-in with a fixed answer.
@MainActor
final class FakeAuthenticator: OwnerAuthenticator {
    var answer: OwnerCheck
    private(set) var asked = 0

    init(_ answer: OwnerCheck) { self.answer = answer }

    func confirm(reason: String) async -> OwnerCheck {
        asked += 1
        return answer
    }
}

@MainActor
@Suite(.serialized) struct ConsentApprovalTests {
    func pendingApproval(_ fixture: ChatFixture) -> ChatApproval {
        ChatApproval(id: "req-1", profileID: fixture.home.id, command: "rm -rf build", details: "Clean the build folder", mailID: nil)
    }

    func approvals(_ fixture: ChatFixture) -> [String] {
        fixture.links.sent.filter { $0.body["type"]?.string == "approval" }.compactMap { $0.body["choice"]?.string }
    }

    // MARK: approvals (C8)

    @Test func cancelledFaceIDKeepsTheRequestOpenForARetry() async throws {
        let fixture = try ChatFixture()
        let auth = FakeAuthenticator(.cancelled)
        fixture.chat.authenticator = auth
        fixture.chat.pendingApproval = pendingApproval(fixture)
        await fixture.chat.answerApproval(approve: true)
        #expect(auth.asked == 1)
        #expect(fixture.chat.pendingApproval?.id == "req-1")
        #expect(fixture.chat.approvalStep == .retry)
        #expect(approvals(fixture).isEmpty, "a cancelled Face ID must not deny the command")

        auth.answer = .confirmed
        await fixture.chat.answerApproval(approve: true)
        #expect(fixture.chat.pendingApproval == nil)
        #expect(approvals(fixture) == ["once"])
    }

    @Test func denyingNeverAsksForFaceID() async throws {
        let fixture = try ChatFixture()
        let auth = FakeAuthenticator(.confirmed)
        fixture.chat.authenticator = auth
        fixture.chat.pendingApproval = pendingApproval(fixture)
        await fixture.chat.answerApproval(approve: false)
        #expect(auth.asked == 0)
        #expect(approvals(fixture) == ["deny"])
    }

    @Test func noPasscodeLeavesOnlyDeny() async throws {
        let fixture = try ChatFixture()
        fixture.chat.authenticator = FakeAuthenticator(.unavailable)
        fixture.chat.pendingApproval = pendingApproval(fixture)
        await fixture.chat.answerApproval(approve: true)
        #expect(fixture.chat.approvalStep == .unavailable)
        #expect(fixture.chat.pendingApproval != nil && approvals(fixture).isEmpty)
    }

    // MARK: session approvals (Hermes ≥ 0.15)

    @Test func sessionChoiceIsOfferedOnlyWhenTheBridgeListsIt() {
        #expect(ApprovalChoice.allowsSession(["type": "approval_request", "choices": ["once", "session", "deny"]]))
        #expect(!ApprovalChoice.allowsSession(["type": "approval_request", "choices": ["once", "deny"]]))
        #expect(!ApprovalChoice.allowsSession(["type": "approval_request"]), "older bridges: once/deny")
    }

    @Test func allowForThisSessionNeedsFaceIDToo() async throws {
        let fixture = try ChatFixture()
        let auth = FakeAuthenticator(.cancelled)
        fixture.chat.authenticator = auth
        var approval = pendingApproval(fixture)
        approval.allowsSession = true
        fixture.chat.pendingApproval = approval
        await fixture.chat.answerApproval(.session)
        #expect(auth.asked == 1 && approvals(fixture).isEmpty && fixture.chat.approvalStep == .retry)
        auth.answer = .confirmed
        await fixture.chat.answerApproval(.session)
        #expect(approvals(fixture) == ["session"])
        #expect(fixture.chat.pendingApproval == nil)
    }

    @Test func sessionIsNeverSentWhenNotOffered() async throws {
        let fixture = try ChatFixture()
        fixture.chat.authenticator = FakeAuthenticator(.confirmed)
        fixture.chat.pendingApproval = pendingApproval(fixture)
        await fixture.chat.answerApproval(.session)
        #expect(approvals(fixture).isEmpty)
        #expect(fixture.chat.pendingApproval?.id == "req-1")
    }

    @Test func approvalStepsAfterAChecks() {
        #expect(ApprovalStep.after(.cancelled) == .retry)
        #expect(ApprovalStep.after(.unavailable) == .unavailable)
        #expect(ApprovalStep.after(.confirmed) == .waiting)
    }

    // MARK: consent (B2)

    @Test func nothingIsSentBeforeConsent() async throws {
        let fixture = try ChatFixture()
        fixture.app.preferences.aiConsent = false
        #expect(await fixture.chat.send(text: "hello") == nil)
        #expect(fixture.links.sent.isEmpty)
        #expect(fixture.app.error == .consentRequired)
        #expect(fixture.app.error?.recovery == .reviewConsent)
    }

    @Test func outboxWaitsForConsent() async throws {
        let fixture = try ChatFixture()
        fixture.app.preferences.aiConsent = false
        let waiting = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: "from the share sheet", status: .pending)
        try await fixture.store.upsert(waiting, in: fixture.home.id)
        await fixture.chat.drainOutbox()
        #expect(fixture.links.sent.isEmpty)
        fixture.app.preferences.aiConsent = true
        await fixture.chat.drainOutbox()
        #expect(fixture.links.sent.count == 1)
    }

    @Test func callsWaitForConsent() async throws {
        let fixture = try ChatFixture()
        fixture.app.preferences.aiConsent = false
        let calls = CallCoordinator(app: fixture.app)
        await calls.startCall()
        #expect(!calls.inCall && calls.phase == .idle)
        #expect(fixture.app.error == .consentRequired)
    }

    @Test func phoneQueriesAreDeniedWithoutConsent() throws {
        let query = try #require(PhoneQuery.parse(Self.query(.battery)))
        #expect(PhoneContextModel.decision(consent: false, permission: .yes, for: query) == .deny)
        #expect(PhoneContextModel.decision(consent: true, permission: .yes, for: query) == .answer)
        #expect(PhoneContextModel.decision(consent: true, permission: .ask, for: query) == .ask)
        #expect(PhoneContextModel.decision(consent: true, permission: .no, for: query) == .deny)
    }

    @Test func consentIsStoredForTheExtensions() {
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, shared: defaults)
        #expect(!preferences.aiConsent)
        preferences.aiConsent = true
        #expect(defaults.integer(forKey: SharedContainer.aiConsentKey) == SharedContainer.aiConsentVersion)
        #expect(Preferences(defaults: defaults, shared: defaults).aiConsent)
        preferences.reset()
        #expect(!Preferences(defaults: defaults, shared: defaults).aiConsent)
    }

    // MARK: errors (F7)

    @Test func errorsCarryTheirRecovery() {
        #expect(AppError.microphoneDenied.recovery == .openSettings)
        #expect(AppError.cameraDenied.recoveryTitle == "Open Settings")
        #expect(AppError.profileDamaged(agent: "Atlas").recovery == .showRelays)
        #expect(AppError.profileDamaged(agent: "Atlas").message.contains("Atlas"))
        #expect(AppError.message("x").recovery == nil)
    }

    @Test func plainTextErrorsStillShow() throws {
        let fixture = try ChatFixture()
        fixture.app.lastError = "The message could not be saved."
        #expect(fixture.app.error == .message("The message could not be saved."))
        fixture.app.lastError = nil
        #expect(fixture.app.error == nil)
    }

    static func query(_ capability: PhoneCapability, params: [String: JSON] = [:]) -> [String: JSON] {
        ["type": "phone_query", "query_id": .string(Base64URL.encode(Sodium.randomBytes(16))), "capability": .string(capability.rawValue),
         "reason": "Checking", "expires": .int(Int64((Date().timeIntervalSince1970 + 60) * 1000)), "params": .object(params)]
    }
}
