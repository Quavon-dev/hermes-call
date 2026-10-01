import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// The emergency stop: `/stop` through the durable chat path, shown as "Stop requested".
@MainActor
@Suite(.serialized) struct StopAgentTests {
    @Test func stopIsSentAsAPlainChatMessageAndStoredAsAStopRequest() async throws {
        let fixture = try ChatFixture()
        let result = await fixture.chat.requestStop(profileID: fixture.office.id)
        #expect(result == .delivered)
        let sent = try #require(fixture.links.sent.last)
        #expect(sent.profile == fixture.office.id)
        #expect(sent.body["type"]?.string == "chat" && sent.body["text"]?.string == "/stop")
        let stored = try #require(await fixture.store.latest(fixture.office.id, limit: 1).last)
        #expect(stored.isStopRequest && stored.kind == StopCommand.kind && stored.status == .delivered)
        #expect(stored.preview == "Stop requested")
    }

    @Test func stopWaitsInTheOutboxWhenTheRelayIsOffline() async throws {
        let fixture = try ChatFixture()
        fixture.links.reachable = false
        #expect(await fixture.chat.requestStop() == .queued)
        let stored = try #require(await fixture.store.latest(fixture.home.id, limit: 1).last)
        #expect(stored.isStopRequest && stored.status != .delivered)
    }

    @Test func stopNeedsConsentLikeEverySend() async throws {
        let fixture = try ChatFixture()
        fixture.app.preferences.aiConsent = false
        #expect(await fixture.chat.requestStop() == .unavailable)
        #expect(fixture.links.sent.isEmpty)
    }

    @Test func demoStopCancelsTheDemoReply() async throws {
        let (app, _) = DemoAndRoutingTests().emptyApp()
        app.startDemo()
        let store = ChatStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)"),
                              changedSignal: nil)
        let links = AgentLinks(app: app)
        links.demo.thinking = .milliseconds(400)
        let chat = ChatModel(app: app, store: store, links: links, listens: false)
        links.demo.chat = chat
        await chat.reload()
        _ = try #require(await chat.send(text: "Plan my day"))
        #expect(await chat.requestStop() == .delivered)
        try await Task.sleep(for: .milliseconds(900))
        let agent = await store.latest(DemoAgent.id, limit: 10).filter { $0.role == .agent }
        // The plan never arrives; the demo answers like Hermes' gateway does.
        #expect(agent.map(\.text) == [DemoLinkProvider.stoppedReply])
    }

    @Test func tasksRingOffersStop() {
        #expect(PresenceIntent.action(for: .tapRing(3), inCall: false, talkMode: nil, canCall: true, ringKind: .tasks) == .offerStop)
        #expect(PresenceIntent.action(for: .tapRing(3), inCall: true, talkMode: .handsFree, canCall: true, ringKind: .tasks) == .offerStop)
    }
}
