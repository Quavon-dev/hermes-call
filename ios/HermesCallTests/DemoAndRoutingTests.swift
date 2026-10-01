import AVFoundation
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

@MainActor
@Suite(.serialized) struct DemoAndRoutingTests {
    /// An app with no paired agents and private stores.
    func emptyApp() -> (AppModel, ProfileStore) {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "de.quavon.hermescall.tests.\(UUID().uuidString)") ?? .standard
        return (AppModel(store: store, preferences: Preferences(defaults: defaults, shared: defaults)), store)
    }

    // MARK: demo agent (B1)

    @Test func demoAgentIsNeverStoredWithTheRealAgents() async throws {
        let (app, store) = emptyApp()
        app.startDemo()
        #expect(app.activeProfile?.isDemo == true)
        #expect(app.relayStatus == .connected)
        #expect(app.realProfiles.isEmpty)
        #expect(try store.load().isEmpty, "the demo profile must not reach the Keychain")
        let demo = try #require(app.activeProfile)
        #expect(throws: ProtocolError.self) { try app.borrowSession(for: demo) }
        app.rename(DemoAgent.id, to: "renamed")
        #expect(try store.load().isEmpty)
        await app.removeDemo()
        #expect(app.profiles.isEmpty && !app.preferences.demoActive)
    }

    @Test func demoChatAnswersOnThePhone() async throws {
        let (app, _) = emptyApp()
        app.startDemo()
        let store = ChatStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)"),
                              changedSignal: nil)
        let links = AgentLinks(app: app)
        links.demo.thinking = .milliseconds(10)
        let chat = ChatModel(app: app, store: store, links: links, listens: false)
        links.demo.chat = chat
        await chat.reload()
        // No consent needed: nothing leaves the phone.
        let id = try #require(await chat.send(text: "Find a place for dinner"))
        #expect(await store.message(id, in: DemoAgent.id)?.status == .delivered)
        var reply: ChatMessage?
        for _ in 0..<100 where reply == nil {
            reply = await store.latest(DemoAgent.id, limit: 5).last { $0.role == .agent }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reply?.presentation?.kind == .places)
        #expect(reply?.presentation?.items.count == 3)
    }

    @Test func demoAgentRepliesByTopic() {
        #expect(DemoAgent.topic(of: "hello") == .greeting)
        #expect(DemoAgent.topic(of: "Plan my day") == .plan)
        #expect(DemoAgent.topic(of: "any coffee nearby?") == .places)
        #expect(DemoAgent.topic(of: "call me later") == .call)
        #expect(DemoAgent.topic(of: "", attachments: 1) == .attachment)
        #expect(DemoAgent.topic(of: "what is the meaning of life") == .echo)
        let reply = DemoAgent.reply(to: "plan")
        #expect(ChatWire.message(from: reply)?.role == .agent)
        #expect(ChatWire.message(from: DemoAgent.reply(to: "places"))?.presentation != nil)
    }

    @Test func demoCallIsSimulatedWithoutCallKit() async throws {
        let (app, _) = emptyApp()
        app.startDemo()
        var ended: TimeInterval?
        let calls = CallCoordinator(app: app)
        calls.onCallEnded = { _, duration, _ in ended = duration }
        await calls.startCall()
        #expect(calls.inCall && calls.isDemoCall && calls.isConnected)
        #expect(calls.peerName == DemoAgent.name)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!calls.captions.isEmpty)
        #expect(calls.liveLevels() != nil)
        calls.hangUp()
        #expect(!calls.inCall && calls.phase == .ended(reason: "Call ended."))
        #expect(ended != nil)
    }

    // MARK: message router (L3)

    @Test func routerSendsEachMessageToItsOwner() {
        #expect(MessageRouter.destination(for: ["type": "chat", "id": "x"]) == .chat)
        #expect(MessageRouter.destination(for: ["type": "approval_request", "chat": true]) == .chat)
        #expect(MessageRouter.destination(for: ["type": "approval_request", "call_id": "c"]) == .call)
        #expect(MessageRouter.destination(for: ["type": "phone_query"]) == .phone)
        #expect(MessageRouter.destination(for: ["type": "query_done"]) == .phone)
        #expect(MessageRouter.destination(for: ["type": "task"]) == .task)
        #expect(MessageRouter.destination(for: ["type": "invite", "call_id": "c"]) == .call)
        #expect(MessageRouter.destination(for: ["type": "something_new"]) == .drop)
    }

    // MARK: calls (C3, C2)

    @Test func pushRingsNameTheAgent() {
        #expect(CallCoordinator.ringName(["Atlas"]) == "Atlas")
        #expect(CallCoordinator.ringName(["Atlas", "Atlas"]) == "Atlas")
        #expect(CallCoordinator.ringName(["Atlas", "Nova"]) == "Atlas or Nova")
        #expect(CallCoordinator.ringName(["Atlas", "Nova", "Iris"]) == "Your agent")
        #expect(CallCoordinator.iconTemplate != nil)
        #expect(CallCoordinator.configuration(includeInRecents: true).iconTemplateImageData != nil)
    }

    @Test func speakerFollowsTheRealRoute() {
        #expect(CallAudioRoute.isSpeaker([.builtInSpeaker]))
        #expect(!CallAudioRoute.isSpeaker([.builtInReceiver]))
        #expect(!CallAudioRoute.isSpeaker([.bluetoothHFP]))
        let began = CallAudioRoute.interruption([AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(began == (true, false))
        let ended = CallAudioRoute.interruption([AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                 AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        #expect(ended == (false, true))
    }

    // MARK: presence (F1) and network (F6)

    @Test func presenceSlowsDownWhenHotOrSaving() {
        #expect(FrameBudget.framesPerSecond(reduceMotion: false, lowPower: false, thermal: .nominal) == 120)
        #expect(FrameBudget.framesPerSecond(reduceMotion: false, lowPower: true, thermal: .nominal) == 30)
        #expect(FrameBudget.framesPerSecond(reduceMotion: true, lowPower: false, thermal: .fair) == 30)
        #expect(FrameBudget.framesPerSecond(reduceMotion: false, lowPower: false, thermal: .serious) == 30)
        #expect(FrameBudget.framesPerSecond(reduceMotion: false, lowPower: false, thermal: .critical) == 20)
    }

    @Test func networkChangesReconnectAtOnce() {
        #expect(NetworkMonitor.shouldReconnect(wasOnline: false, isOnline: true, before: [], after: [.wifi]))
        #expect(NetworkMonitor.shouldReconnect(wasOnline: true, isOnline: true, before: [.wifi], after: [.cellular]))
        #expect(!NetworkMonitor.shouldReconnect(wasOnline: true, isOnline: true, before: [.wifi], after: [.wifi]))
        #expect(!NetworkMonitor.shouldReconnect(wasOnline: true, isOnline: false, before: [.wifi], after: []))
        let monitor = NetworkMonitor()
        var restored = 0
        monitor.onPathRestored = { restored += 1 }
        monitor.update(online: false, expensive: false, interfaces: [])
        monitor.update(online: true, expensive: false, interfaces: [.wifi])
        #expect(restored == 1 && monitor.isOnline)
    }

    // MARK: diagnostics (F5)

    @Test func exportedLogIsRedacted() {
        let line = "push registered for owner@example.com via relay.example.com 203.0.113.7 token 0a1b2c3d4e5f60718293a4b5c6d7e8f9 "
            + "id 6F9619FF-8B86-D011-B42D-00C04FC964FF key AbCdEfGhIjKlMnOpQrStUvWxYz012345_-"
        let redacted = DiagnosticLog.redact(line)
        for secret in ["owner@example.com", "relay.example.com", "203.0.113.7", "0a1b2c3d4e5f", "6F9619FF", "AbCdEfGhIjKl"] {
            #expect(!redacted.contains(secret), "\(secret) leaked")
        }
        #expect(redacted.contains("push registered"))
    }

    @Test func exportedLogRedactsStandardBase64AndPairingCodes() {
        let line = "sig q3Zk+9/aB1c2+d3E4/f5g6H7i8j9k0lMnO== code K7Q-4TXP9 and r7kq4mop link c=ABC12345 box AbCd+EfGh/IjKl+Mn1p/QrSt+UvWx= "
            + "done in 120 ms, status CANCELED, path /var/lib/hermescall"
        let redacted = DiagnosticLog.redact(line)
        for secret in ["q3Zk", "9/aB1c2", "K7Q-4TXP9", "4TXP9", "r7kq4mop", "ABC12345", "AbCd", "Mn1p", "UvWx"] {
            #expect(!redacted.contains(secret), "\(secret) leaked: \(redacted)")
        }
        for kept in ["done in 120 ms", "CANCELED", "/var/lib/hermescall"] {
            #expect(redacted.contains(kept), "\(kept) was redacted: \(redacted)")
        }
    }
}
