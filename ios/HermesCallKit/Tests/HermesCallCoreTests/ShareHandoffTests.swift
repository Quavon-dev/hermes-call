import Foundation
import Synchronization
import Testing
@testable import HermesCallCore

/// The share extension must not open its own relay connection while the app has one: the relay keeps
/// one connection per device and would drop the app's.
struct ShareHandoffTests {
    let store = ChatStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)"),
                          changedSignal: nil)
    let profile = UUID()

    func pending() async throws -> ChatMessage {
        let message = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: "shared link", status: .pending)
        try await store.upsert(message, in: profile)
        return message
    }

    @Test func aRunningAppSendsIt() async throws {
        let message = try await pending()
        let sentHere = Mutex(false)
        let route = await ShareHandoff.deliver(message, profile: profile, store: store, appIsRunning: { true }) {
            sentHere.withLock { $0 = true }
            return true
        }
        #expect(route == .app)
        #expect(sentHere.withLock { $0 } == false)
        #expect(await store.outbox(profile).map(\.message.id) == [message.id])
    }

    @Test func withoutTheAppTheExtensionSendsItself() async throws {
        let message = try await pending()
        #expect(await ShareHandoff.deliver(message, profile: profile, store: store, appIsRunning: { false }) { true } == .sentHere)
        #expect(await store.message(message.id, in: profile)?.status == .delivered)
        let unconfirmed = try await pending()
        #expect(await ShareHandoff.deliver(unconfirmed, profile: profile, store: store, appIsRunning: { false }) { false } == .waiting)
        #expect(await store.outbox(profile).map(\.message.id) == [unconfirmed.id])
    }

    @Test func aMessageTheAppIsSendingIsLeftAlone() async throws {
        let message = try await pending()
        #expect(await store.claim(message.id, in: profile, owner: "app", for: 60))
        let sentHere = Mutex(false)
        let route = await ShareHandoff.deliver(message, profile: profile, store: store, appIsRunning: { false }) {
            sentHere.withLock { $0 = true }
            return true
        }
        #expect(route == .app && sentHere.withLock { $0 } == false)
    }
}
