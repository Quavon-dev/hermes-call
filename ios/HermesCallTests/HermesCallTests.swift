import AVFoundation
import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

@MainActor
@Suite(.serialized) struct AppTests {
    func sampleProfile(label: String = "home") throws -> RelayProfile {
        RelayProfile(id: UUID(), label: label, relay: RelayAddress(host: "relay.example.com", port: 443), pin: "",
                     deviceID: "dev", bridgeID: "bridge", bridgeName: "Hermes",
                     bridgeBoxKey: Base64URL.encode(Sodium.randomBytes(32)),
                     bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: try DeviceKeys.generate(), created: Date())
    }

    @Test func keychainStoreRoundTripAndWipe() throws {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        #expect(try store.load().isEmpty)
        let profiles = [try sampleProfile(label: "home"), try sampleProfile(label: "vps")]
        try store.save(profiles)
        #expect(try store.load() == profiles)
        try store.save([profiles[1]])
        #expect(try store.load() == [profiles[1]])
        try store.deleteAll()
        #expect(try store.load().isEmpty)
    }

    @Test func preferencesPersistAndReset() {
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.talkMode == .handsFree && prefs.includeInRecents)
        prefs.talkMode = .pushToTalk
        prefs.includeInRecents = false
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.talkMode == .pushToTalk && !reloaded.includeInRecents)
        reloaded.reset()
        #expect(Preferences(defaults: defaults).talkMode == .handsFree)
    }

    @Test func appModelActivatesAndDeletesProfiles() async throws {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [try sampleProfile(label: "home"), try sampleProfile(label: "vps")]
        try store.save(profiles)
        let model = AppModel(store: store, preferences: Preferences(defaults: defaults))
        #expect(model.activeProfile?.label == "home")
        model.activate(profiles[1].id)
        #expect(model.activeProfile?.label == "vps")
        model.rename(profiles[1].id, to: "  Hetzner VPS  ")
        #expect(try store.load()[1].label == "Hetzner VPS")
        model.disconnect()
        await model.deleteAllData()
        #expect(model.profiles.isEmpty)
        let remaining = try store.load()
        #expect(remaining.isEmpty)
    }

    @Test func pushPayloadMustBeExactlyACallID() {
        let callID = Base64URL.encode(Sodium.randomBytes(16))
        #expect(IncomingPush.callID(from: ["c": callID]) == callID)
        #expect(IncomingPush.callID(from: [:]) == nil)
        #expect(IncomingPush.callID(from: ["c": 5]) == nil)
        #expect(IncomingPush.callID(from: ["c": Base64URL.encode(Sodium.randomBytes(15))]) == nil)
        #expect(IncomingPush.callID(from: ["c": "not base64!"]) == nil)
        #expect(IncomingPush.callID(from: ["c": callID, "aps": ["alert": "x"]]) == nil)
    }

    @Test func turnServersMustBeOnTheRelayHost() {
        #expect(WebRTCCall.isRelayTURN("turn:relay.example.com:3478?transport=udp", host: "relay.example.com"))
        #expect(WebRTCCall.isRelayTURN("turns:Relay.Example.com:5349", host: "relay.example.com"))
        #expect(WebRTCCall.isRelayTURN("turn:[2001:db8::1]:3478", host: "[2001:db8::1]"))
        #expect(!WebRTCCall.isRelayTURN("turn:evil.example:3478", host: "relay.example.com"))
        #expect(!WebRTCCall.isRelayTURN("stun:relay.example.com:3478", host: "relay.example.com"))
        #expect(!WebRTCCall.isRelayTURN("turn:relay.example.com.evil.example:3478", host: "relay.example.com"))
    }

    @Test func ringbackToneIsAFiveSecondLoopableWav() throws {
        let player = try AVAudioPlayer(data: RingbackTone.wav)
        #expect(abs(player.duration - 5) < 0.01)
    }

    @Test func callIDMapsToOneStableCallKitUUID() throws {
        let bytes = Sodium.randomBytes(16)
        let uuid = try #require(CallCoordinator.callUUID(Base64URL.encode(bytes)))
        #expect(CallCoordinator.callUUID(Base64URL.encode(bytes)) == uuid)
        #expect(withUnsafeBytes(of: uuid.uuid) { Data($0) } == bytes)
        #expect(CallCoordinator.callUUID("short") == nil)
    }

    @Test func apnsEnvironmentFollowsTheProvisioningProfile() {
        func profile(_ body: String) -> Data { Data("\u{30}\u{82}garbage<?xml?><plist><dict>\(body)</dict></plist>".utf8) }
        #expect(PushEnvironment.from(provisioningProfile: profile(
            "<key>Entitlements</key><dict><key>aps-environment</key>\n\t<string>development</string></dict>")) == "sandbox")
        #expect(PushEnvironment.from(provisioningProfile: profile(
            "<key>aps-environment</key><string>production</string>")) == "production")
        #expect(PushEnvironment.from(provisioningProfile: profile("")) == "production")
    }

    @Test func borrowedSessionsAreSharedPerRelayAndReleasedByTheLastUser() async throws {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? store.deleteAll()
        }
        let profiles = [try sampleProfile(label: "home"), try sampleProfile(label: "vps")]
        try store.save(profiles)
        let model = AppModel(store: store, preferences: Preferences(defaults: defaults))
        model.isForeground = true
        let active = try model.borrowSession(for: profiles[0])
        #expect(active === model.session && model.isBorrowed)
        let first = try model.borrowSession(for: profiles[1]), second = try model.borrowSession(for: profiles[1])
        #expect(first === second && first !== active)
        model.releaseSession(first)
        #expect(try model.borrowSession(for: profiles[1]) === first)
        model.releaseSession(first)
        model.releaseSession(first)
        #expect(try model.borrowSession(for: profiles[1]) !== first)

        model.activate(profiles[1].id)
        #expect(model.session !== active)
        #expect(try model.borrowSession(for: profiles[0]) === active)
        model.releaseSession(active)
        model.releaseSession(active)
        // In the foreground the previous agent stays connected (standby): the same session again.
        #expect(try model.borrowSession(for: profiles[0]) === active)
        model.releaseSession(active)

        model.isForeground = false
        let background = try #require(model.session)
        #expect(try model.borrowSession(for: profiles[1]) === background)
        model.releaseSession(background)
        #expect(model.session === background)
        model.releaseSession(background)
        #expect(model.session == nil)
    }

    /// M1: a changed network reconnects borrowed connections too (a ring of another agent via VoIP push).
    @Test func reconnectNowReachesBorrowedSessions() async throws {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? store.deleteAll()
        }
        let profiles = [try sampleProfile(label: "home"), try sampleProfile(label: "vps")]
        try store.save(profiles)
        let model = AppModel(store: store, preferences: Preferences(defaults: defaults))
        model.isForeground = true
        model.connect()
        let active = try #require(model.session)
        let other = try model.borrowSession(for: profiles[1])
        model.enterBackground()
        #expect(model.openSessions.count == 1 && model.openSessions.first === other, "only the borrowed one is left")
        _ = try model.borrowSession(for: profiles[0])
        #expect(model.openSessions.contains { $0 === other } && model.openSessions.count == 2, "each session once")
        _ = active
        for session in model.openSessions { await session.stop() }
    }

    @Test func pushRegistrationsPersistAndReset() {
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.pushRegistrations["p1"] = "sandbox:abcd"
        prefs.speechRecognition = .iPhone
        prefs.appearance = .hud
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.pushRegistrations == ["p1": "sandbox:abcd"])
        #expect(reloaded.speechRecognition == .iPhone && reloaded.appearance == .hud)
        prefs.reset()
        #expect(Preferences(defaults: defaults).pushRegistrations.isEmpty)
    }

    @Test func callKitConfigurationFollowsRecentsSetting() {
        #expect(CallCoordinator.configuration(includeInRecents: false).includesCallsInRecents == false)
        let config = CallCoordinator.configuration(includeInRecents: true)
        #expect(config.includesCallsInRecents && !config.supportsVideo && config.maximumCallGroups == 1)
    }

    @Test func presenceMoodFollowsTheConversation() {
        var mood = PresenceMood()
        let start = Date()
        mood.update(agent: 0, mic: 0, muted: false, now: start)
        #expect(mood.state == .idle)
        mood.update(agent: 0, mic: 0.2, muted: false, now: start)
        #expect(mood.state == .listening)
        mood.update(agent: 0, mic: 0.01, muted: false, now: start.addingTimeInterval(0.3))
        #expect(mood.state == .listening)  // pause between words
        mood.update(agent: 0, mic: 0.01, muted: false, now: start.addingTimeInterval(2))
        #expect(mood.state == .thinking)
        mood.update(agent: 0.3, mic: 0, muted: false, now: start.addingTimeInterval(3))
        #expect(mood.state == .speaking)
        mood.update(agent: 0, mic: 0, muted: false, now: start.addingTimeInterval(4))
        #expect(mood.state == .idle)
        mood.update(agent: 0, mic: 0.5, muted: true, now: start.addingTimeInterval(5))
        #expect(mood.state == .idle)  // muted mic never counts
        mood.update(agent: 0, mic: 0.2, muted: false, now: start.addingTimeInterval(6))
        mood.update(agent: 0, mic: 0, muted: false, now: start.addingTimeInterval(6 + PresenceMood.thinkingWindow + 1))
        #expect(mood.state == .idle)  // gave up waiting
    }

    // MARK: presence

    @Test func presenceGestureMap() {
        func act(_ gesture: PresenceGesture, inCall: Bool = false, mode: TalkMode? = nil, canCall: Bool = true,
                 ring: PresenceRingKind? = nil) -> PresenceAction {
            PresenceIntent.action(for: gesture, inCall: inCall, talkMode: mode, canCall: canCall, ringKind: ring)
        }
        #expect(act(.tapHeart) == .startCall(.handsFree))
        #expect(act(.tapHeart, canCall: false) == .none)
        #expect(act(.tapHeart, inCall: true, mode: .handsFree) == .interrupt)
        #expect(act(.holdBegan) == .startCall(.pushToTalk))
        #expect(act(.holdBegan, inCall: true, mode: .pushToTalk) == .beginTalking)
        #expect(act(.holdBegan, inCall: true, mode: .handsFree) == .interrupt)
        #expect(act(.holdEnded, inCall: true, mode: .pushToTalk) == .endTalking)
        #expect(act(.holdEnded) == .none)
        #expect(act(.tapRing(1), ring: .messages) == .openHistory)
        #expect(act(.tapRing(0), inCall: true, ring: .requests) == .showRequests)
        #expect(act(.tapRing(2), ring: .results) == .showResults)
        #expect(act(.swipeUp) == .openHistory)
        #expect(act(.swipeDown) == .none)
        #expect(act(.swipeDown, inCall: true) == .endCall)
        #expect(act(.longPressSpace(CGPoint(x: 5, y: 6))) == .openMenu(CGPoint(x: 5, y: 6)))
        #expect(act(.swipeLeft) == .switchAgent(1))
        #expect(act(.swipeRight) == .switchAgent(-1))
        #expect(act(.swipeLeft, inCall: true) == .none)  // never switch agents during a call
    }

    @Test func presenceTouchClassification() {
        var tap = PresenceTouch(at: .zero, onHeart: true, onSphere: true)
        #expect(tap.move(to: CGPoint(x: 3, y: 3)) == nil)
        #expect(tap.end(at: CGPoint(x: 3, y: 3), ring: nil) == .tapHeart)

        var ringTap = PresenceTouch(at: .zero, onHeart: false, onSphere: true)
        #expect(ringTap.end(at: .zero, ring: 2) == .tapRing(2))

        var hold = PresenceTouch(at: .zero, onHeart: true, onSphere: true)
        #expect(hold.holdElapsed() == .holdBegan)
        #expect(hold.holdElapsed() == nil)
        #expect(hold.end(at: .zero, ring: nil) == .holdEnded)

        var spin = PresenceTouch(at: .zero, onHeart: false, onSphere: true)
        #expect(spin.move(to: CGPoint(x: 20, y: 0)) == CGSize(width: 20, height: 0))
        #expect(spin.move(to: CGPoint(x: 25, y: 2)) == CGSize(width: 5, height: 2))
        #expect(spin.holdElapsed() == nil)
        #expect(spin.end(at: CGPoint(x: 25, y: 2), ring: nil) == nil)

        var swipe = PresenceTouch(at: CGPoint(x: 100, y: 700), onHeart: false, onSphere: false)
        _ = swipe.move(to: CGPoint(x: 102, y: 600))
        #expect(swipe.end(at: CGPoint(x: 102, y: 560), ring: nil) == .swipeUp)

        var shortSwipe = PresenceTouch(at: CGPoint(x: 100, y: 700), onHeart: false, onSphere: false)
        _ = shortSwipe.move(to: CGPoint(x: 100, y: 660))
        #expect(shortSwipe.end(at: CGPoint(x: 100, y: 660), ring: nil) == nil)

        var left = PresenceTouch(at: CGPoint(x: 300, y: 700), onHeart: false, onSphere: false)
        _ = left.move(to: CGPoint(x: 250, y: 705))
        #expect(left.end(at: CGPoint(x: 200, y: 710), ring: nil) == .swipeLeft)

        var right = PresenceTouch(at: CGPoint(x: 100, y: 700), onHeart: false, onSphere: false)
        _ = right.move(to: CGPoint(x: 150, y: 700))
        #expect(right.end(at: CGPoint(x: 190, y: 690), ring: nil) == .swipeRight)

        var nudge = PresenceTouch(at: CGPoint(x: 100, y: 700), onHeart: false, onSphere: false)
        _ = nudge.move(to: CGPoint(x: 130, y: 700))
        #expect(nudge.end(at: CGPoint(x: 150, y: 700), ring: nil) == nil)

        var press = PresenceTouch(at: CGPoint(x: 40, y: 50), onHeart: false, onSphere: false)
        #expect(press.holdElapsed() == .longPressSpace(CGPoint(x: 40, y: 50)))
    }

    @Test func presenceRingsReflectWhatWaits() {
        let quiet = PresenceRings.states(unread: 0, requests: 0, hasResults: false)
        #expect(quiet.allSatisfy { $0.lit == 0 })
        let busy = PresenceRings.states(unread: 2, requests: 1, hasResults: true, focused: PresenceRings.messagesRing)
        #expect(busy[PresenceRings.requestsRing].kind == .requests && busy[PresenceRings.requestsRing].lit == 5)
        #expect(busy[PresenceRings.messagesRing].lit == 8 && busy[PresenceRings.messagesRing].focused)
        #expect(busy[PresenceRings.resultsRing].lit > 0)
        let flood = PresenceRings.states(unread: 500, requests: 0, hasResults: false)
        #expect(flood[PresenceRings.messagesRing].lit == PresenceGeometry.rings[PresenceRings.messagesRing].blocks)
        #expect(PresenceRings.summary(busy[PresenceRings.requestsRing]) == "Waiting for your decision")
        #expect(PresenceRings.summary(quiet[0]) == nil)
    }

    @MainActor @Test func presenceHitTesting() {
        let engine = PresenceEngine()
        engine.place(center: CGPoint(x: 200, y: 400), radius: 150, animated: false)
        #expect(engine.isInHeart(CGPoint(x: 210, y: 395)))
        #expect(!engine.isInHeart(CGPoint(x: 200, y: 520)))
        #expect(engine.isOnSphere(CGPoint(x: 200, y: 520)))
        #expect(!engine.isOnSphere(CGPoint(x: 20, y: 60)))
        // Quiet rings are never hit; a lit ring is hit on its visible curve.
        #expect(engine.ring(at: CGPoint(x: 200, y: 400)) == nil)
        engine.rings = PresenceRings.states(unread: 3, requests: 0, hasResults: false)
        let ring = PresenceGeometry.rings[PresenceRings.messagesRing]
        let (point, _) = PresenceGeometry.project(PresenceGeometry.point(on: ring, angle: 0.3, radius: ring.radius),
                                                  rotation: engine.rotation, center: engine.center, radius: engine.radius)
        #expect(engine.ring(at: point) == PresenceRings.messagesRing)
    }

    @MainActor @Test func presenceUniformsAreComplete() {
        let engine = PresenceEngine()
        let uniforms = engine.step(drawable: CGSize(width: 1206, height: 2622), scale: 3)
        #expect(uniforms.count == PresenceEngine.uniformCount)
        #expect(uniforms[16].x == AgentPalette.gold.glow.r)  // palette slots
        #expect(uniforms[0].x == 1206 && uniforms[1].z == 3)
        #expect(uniforms.allSatisfy { !$0.x.isNaN && !$0.y.isNaN && !$0.z.isNaN && !$0.w.isNaN })
    }

    // MARK: M9

    @Test func tasksRingFillsWithProgress() {
        func task(_ step: Int, total: Int? = nil, state: TaskContentState.State = .running) -> TaskUpdate {
            TaskUpdate(turnID: "t", step: step, total: total, tool: "web_search", label: "Searching the web", preview: nil,
                       state: state, startedAt: 1)
        }
        let blocks = PresenceGeometry.rings[PresenceRings.tasksRing].blocks
        let half = PresenceRings.states(unread: 0, requests: 0, hasResults: false, task: task(2, total: 4))[PresenceRings.tasksRing]
        #expect(half.kind == .tasks && half.active && half.lit == blocks / 2)
        let open = PresenceRings.taskRing(task(3))
        #expect(open.lit == 30 && open.active)
        #expect(PresenceRings.taskRing(task(99)).lit == blocks - 10)  // never looks finished while running
        let done = PresenceRings.taskRing(task(3, state: .done))
        #expect(done.lit == blocks && !done.active)
        #expect(PresenceRings.summary(open) == "Working")
        #expect(PresenceRings.states(unread: 0, requests: 0, hasResults: false)[PresenceRings.tasksRing].kind == .plain)
    }

    @Test func appIconFollowsAppearanceUnlessChosen() {
        #expect(AppIconChoice.automatic.iconName(for: .standard) == nil)
        #expect(AppIconChoice.automatic.iconName(for: .hud) == AppIconChoice.presenceIcon)
        #expect(AppIconChoice.standard.iconName(for: .hud) == nil)
        #expect(AppIconChoice.presence.iconName(for: .standard) == AppIconChoice.presenceIcon)
    }

    @Test func placeReminderMessageNamesPlaceAndNote() {
        let reminder = PlaceReminder(title: "Buy milk", note: "2 litres", placeName: "Rewe, München", latitude: 1, longitude: 2,
                                     radius: 150, trigger: .enter, repeats: false)
        #expect(PlaceMonitor.message(for: reminder) == "📍 I arrived at Rewe, München. Reminder: Buy milk (2 litres)")
    }

    @MainActor @Test func presencePaletteBlendsToTheAgentsColour() {
        let engine = PresenceEngine()
        engine.palette = .ice
        engine.snapPalette()
        let uniforms = engine.step(drawable: CGSize(width: 300, height: 600), scale: 2)
        #expect(uniforms[16].x == AgentPalette.ice.glow.r && uniforms[19].z == AgentPalette.ice.ember.b)
        engine.bandSource = { [0.9, 0, 0, 0, 0, 0, 0, 0.4] }
        let live = engine.step(drawable: CGSize(width: 300, height: 600), scale: 2)
        #expect(live[14].x == 0.9 && live[15].w == 0.4)
    }

    @Test func agentsSwitchInOrderWithTheirColours() async throws {
        let store = ProfileStore(service: "de.quavon.hermescall.tests.\(UUID().uuidString)")
        let suite = "de.quavon.hermescall.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [try sampleProfile(label: "home"), try sampleProfile(label: "work"), try sampleProfile(label: "vps")]
        try store.save(profiles)
        let model = AppModel(store: store, preferences: Preferences(defaults: defaults))
        #expect(model.neighbor(1)?.label == "work")
        #expect(model.neighbor(-1)?.label == "vps")  // wraps around
        model.setPalette(profiles[1].id, to: .emerald)
        model.activate(profiles[1].id)
        #expect(HUDTheme.shared.palette == .emerald)
        #expect(try store.load()[1].agentPalette == .emerald)
        #expect(model.neighbor(1)?.label == "vps")
        model.disconnect()
        await model.deleteAllData()
        #expect(model.neighbor(1) == nil)
    }

    @Test func watchSnapshotRoundTrips() throws {
        let snapshot = WatchSnapshot(agentName: "Atlas", palette: "ice", paired: true,
                                     messages: [.init(id: "a", fromAgent: true, text: "Hi", date: Date(timeIntervalSince1970: 5))])
        #expect(try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }
}
