// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// The combined chat list: unread per agent, badge = sum, and connections that survive switching agents.
@MainActor
@Suite(.serialized) struct InboxTests {
    func agentMessage(_ text: String, to fixture: ChatFixture, from profile: RelayProfile) {
        fixture.chat.handle(["type": "chat", "id": .string(E2EChannel.newMessageID()), "role": "agent", "text": .string(text)],
                            profile: profile, link: FakeLink(profile: profile, owner: fixture.links))
    }

    @Test func unreadIsCountedPerAgentAndTheBadgeIsTheSum() async throws {
        let fixture = try ChatFixture()
        agentMessage("From home", to: fixture, from: fixture.home)
        agentMessage("From office", to: fixture, from: fixture.office)
        agentMessage("Office again", to: fixture, from: fixture.office)
        #expect(await fixture.eventually { fixture.chat.unread == 3 })
        #expect(fixture.chat.unread(for: fixture.home.id) == 1)
        #expect(fixture.chat.unread(for: fixture.office.id) == 2)
        #expect(ChatBadge.count() == 3)

        // Opening the office chat reads only the office messages.
        fixture.app.activate(fixture.office.id)
        await fixture.chat.reload()
        fixture.chat.isVisible = true
        #expect(fixture.chat.unread(for: fixture.office.id) == 0)
        #expect(fixture.chat.unread(for: fixture.home.id) == 1)
        #expect(fixture.chat.unread == 1)
        #expect(ChatBadge.count() == 1)
        fixture.chat.isVisible = false
    }

    @Test func inboxListsEveryAgentNewestFirst() async throws {
        let fixture = try ChatFixture()
        await fixture.chat.refreshInbox()
        #expect(fixture.chat.inbox.map(\.id) == [fixture.home.id, fixture.office.id])
        #expect(fixture.chat.inbox.allSatisfy { $0.latest == nil })
        agentMessage("Office news", to: fixture, from: fixture.office)
        #expect(await fixture.eventually { fixture.chat.inbox.first?.id == fixture.office.id })
        #expect(fixture.chat.inbox.first?.preview == "Office news")
        #expect(fixture.chat.inbox.first?.unread == 1)
        await fixture.chat.refreshInbox()
        #expect(fixture.chat.inbox.first?.latest?.text == "Office news")
    }

    @Test func standingConnectionsAreBoundedAndStartWithTheActiveAgent() throws {
        let profiles = try (0..<7).map { _ in try ChatFixture.profile("agent") }
        let standing = AppModel.standing(profiles, active: profiles[6].id)
        #expect(standing.count == AppModel.maxStanding)
        #expect(standing.first == profiles[6].id)
        #expect(Set(standing).count == standing.count)
        #expect(AppModel.standing(profiles, active: nil).count == AppModel.maxStanding)
        #expect(AppModel.standing([], active: nil).isEmpty)
    }

    @Test func switchingAgentsKeepsTheOtherConnectionOpenInTheForeground() throws {
        let fixture = try ChatFixture()
        let app = fixture.app
        app.isForeground = true
        app.connect()
        let home = try #require(app.openSession(for: fixture.home.id))
        let office = try #require(app.openSession(for: fixture.office.id), "the other agent is connected too")
        #expect(app.session === home)

        app.activate(fixture.office.id)
        #expect(app.session === office, "the standby connection becomes the active one")
        #expect(app.openSession(for: fixture.home.id) === home, "the previous agent's connection is kept")

        app.enterBackground()
        #expect(app.session == nil)
        #expect(app.openSession(for: fixture.home.id) == nil)
        #expect(app.openSession(for: fixture.office.id) == nil)
    }

    @Test func outsideCallLinksAskFirstAndSwitchNothing() throws {
        let fixture = try ChatFixture()
        let app = fixture.app
        let active = try #require(app.activeProfile?.id)
        #expect(active != fixture.office.id)
        #expect(!app.open(.call(agent: fixture.office.id, trusted: false)), "no call without a confirmation")
        #expect(app.activeProfile?.id == active, "an outside link does not change the active agent")
        #expect(app.route == .confirmCall(fixture.office.id))
        #expect(!app.open(.call(agent: UUID(), trusted: false)))
        #expect(app.route == .confirmCall(nil), "an unknown agent id means the active agent")
        app.route = nil
        #expect(!app.open(.chat(agent: nil)) && app.activeProfile?.id == active && app.tab == .chat)
        fixture.app.disconnect()
    }

    @Test func confirmedAndOwnWidgetCallLinksCallTheirAgent() throws {
        let fixture = try ChatFixture()
        let app = fixture.app
        app.route = .confirmCall(fixture.office.id)
        app.confirmCall(fixture.office.id)
        #expect(app.activeProfile?.id == fixture.office.id && app.tab == .call && app.route == nil)
        #expect(app.open(.call(agent: fixture.home.id, trusted: true)), "the widget's own link calls at once")
        #expect(app.activeProfile?.id == fixture.home.id && app.route == nil)
        fixture.app.disconnect()
    }

    @Test func openChatSwitchesAgentAndAsksTheListForIt() throws {
        let fixture = try ChatFixture()
        fixture.app.openChat(fixture.office.id)
        #expect(fixture.app.activeProfile?.id == fixture.office.id)
        #expect(fixture.app.tab == .chat)
        #expect(fixture.app.chatRequest == fixture.office.id)
        fixture.app.disconnect()
    }
}
