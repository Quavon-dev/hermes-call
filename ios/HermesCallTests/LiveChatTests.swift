import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// Live reply drafts (`chat_draft`) and a spoken reply's audio after its text (`chat_attach`).
@MainActor
@Suite(.serialized) struct LiveChatTests {
    func link(_ fixture: ChatFixture, _ profile: RelayProfile) -> FakeLink { FakeLink(profile: profile, owner: fixture.links) }

    @Test func appAsksForDraftsAndFollowingVoice() {
        #expect(AppHello.caps.contains("chat_draft") && AppHello.caps.contains("voice_follow"))
    }

    @Test func draftShowsUntilTheReplyArrivesAndALateDraftIsIgnored() async throws {
        let fixture = try ChatFixture()
        await fixture.chat.reload()
        let profile = try #require(fixture.app.activeProfile)
        fixture.chat.handle(["type": "chat_draft", "draft": "1", "text": "Sure, the weather"], profile: profile,
                            link: link(fixture, profile))
        #expect(await fixture.eventually { fixture.chat.agentDraft == "Sure, the weather" })
        fixture.chat.handle(["type": "chat", "id": .string(E2EChannel.newMessageID()), "role": "agent",
                             "text": "Sure, the weather is sunny."], profile: profile, link: link(fixture, profile))
        #expect(await fixture.eventually { fixture.chat.agentDraft == nil && fixture.chat.messages.count == 1 })
        fixture.chat.handle(["type": "chat_draft", "draft": "1", "text": "Sure, the weather is"], profile: profile,
                            link: link(fixture, profile))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.chat.agentDraft == nil)
    }

    @Test func draftsOfAnotherAgentAreNotShown() async throws {
        let fixture = try ChatFixture()
        await fixture.chat.reload()
        let shown = try #require(fixture.app.activeProfile)
        let other = shown.id == fixture.home.id ? fixture.office : fixture.home
        fixture.chat.handle(["type": "chat_draft", "draft": "1", "text": "Hi"], profile: other, link: link(fixture, other))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.chat.agentDraft == nil)
    }

    @Test func voiceAttachmentJoinsItsMessage() async throws {
        let fixture = try ChatFixture()
        let id = E2EChannel.newMessageID()
        let profile = fixture.home
        fixture.chat.handle(["type": "chat", "id": .string(id), "role": "agent", "text": "Sunny."], profile: profile,
                            link: link(fixture, profile))
        let voice: JSON = .object(["kind": "voice", "blob_id": .string(Base64URL.encode(Sodium.randomBytes(16))),
                                   "key": .string(Base64URL.encode(Sodium.randomBytes(32))), "name": "reply.m4a",
                                   "mime": "audio/mp4", "size": 1200])
        let attach: [String: JSON] = ["type": "chat_attach", "id": .string(id), "attachments": .array([voice])]
        fixture.chat.handle(attach, profile: profile, link: link(fixture, profile))
        fixture.chat.handle(attach, profile: profile, link: link(fixture, profile))  // a resend adds nothing
        #expect(await fixture.eventually {
            await fixture.store.message(id, in: profile.id)?.attachments.map(\.name) == ["reply.m4a"]
        })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fixture.store.message(id, in: profile.id)?.attachments.count == 1)
        #expect(await fixture.store.message(id, in: profile.id)?.text == "Sunny.")
    }

    @Test func attachmentsForAnUnknownMessageAreDropped() {
        #expect(ChatWire.attach(from: ["type": "chat_attach", "id": "nope", "attachments": .array([])]) == nil)
        #expect(ChatWire.draft(from: ["type": "chat_draft", "draft": .string(String(repeating: "x", count: 40)), "text": "a"]) == nil)
    }
}
