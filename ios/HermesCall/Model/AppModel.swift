import Foundation
import HermesCallCore
import os

enum AppTab: Hashable { case call, chat }

/// App state: paired relay profiles, the active relay connection and pairing.
@MainActor @Observable
final class AppModel {
    private(set) var profiles: [RelayProfile] = []
    /// The active agent's connection.
    private(set) var session: RelaySession?
    /// While the app is on screen, up to `maxStanding - 1` other agents stay connected too, so their messages
    /// and rings arrive and switching agents tears nothing down. In the background only pushes and borrowed
    /// connections remain.
    private(set) var standby: [UUID: RelaySession] = [:]
    static let maxStanding = 5
    /// Connection state per agent.
    private(set) var statuses: [UUID: RelaySession.Status] = [:]
    private var connectedAt: [UUID: Date] = [:]
    /// The session each agent's status callbacks belong to (a stopped predecessor must not overwrite it).
    private var sessionTokens: [UUID: UUID] = [:]
    private(set) var pushToken: String?
    /// The alert on screen (RootView), with its recovery action.
    var error: AppError?
    /// Plain-text errors (chat, composer): shown like any other error, without a recovery action.
    var lastError: String? {
        get { error?.message }
        set { error = newValue.map(AppError.message) }
    }
    /// A screen the root view should show (error recovery, `hermescall://pair` links).
    var route: AppRoute?
    /// The active agent's relay connection (the demo agent runs on this iPhone: always connected).
    var relayStatus: RelaySession.Status {
        guard let profile = activeProfile else { return .disconnected }
        return profile.isDemo ? .connected : status(of: profile.id)
    }

    func status(of id: UUID) -> RelaySession.Status { openSession(for: id) == nil ? .disconnected : statuses[id] ?? .disconnected }

    /// When the active relay connection last came up (Diagnostics, presence).
    var connectedSince: Date? { activeProfile.flatMap { connectedAt[$0.id] } }
    func upSince(_ id: UUID) -> Date? { status(of: id) == .connected ? connectedAt[id] : nil }
    /// What each agent's relay said about itself on its last connect (version, caps), for Diagnostics and
    /// for requests that need a cap.
    private(set) var relayInfo: [UUID: RelayInfo] = [:]
    /// What each agent's bridge said in its E2E `hello` (version, caps); missing for older bridges.
    private(set) var bridgeInfo: [UUID: BridgeInfo] = [:]
    /// Lets the call coordinator listen to every relay connection the app opens.
    var onSessionCreated: ((RelaySession) -> Void)?
    /// A relay connection (the app's own or a borrowed one) is up: fetch mail, resend the outbox.
    var onConnected: ((RelaySession) -> Void)?
    /// Which tab is shown; notifications and deep links switch to the chat.
    var tab: AppTab = .call
    /// A chat the chat list should open (notification tap, deep link, intent); the list clears it.
    var chatRequest: UUID?
    private(set) var alertToken: String?

    let preferences: Preferences
    private let store: ProfileStore
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "app")
    /// Sessions in use by calls or push registration, shared so one identity never holds two
    /// connections (the relay would drop the older one). A borrowed session is never stopped under its users.
    private var borrowed: [UUID: (session: RelaySession, users: Int)] = [:]
    /// Set by the app's scene phase; in the background the relay connection is kept only while borrowed.
    var isForeground = false
    private var registeringPush: Set<UUID> = []

    init(store: ProfileStore = ProfileStore(), preferences: Preferences = Preferences()) {
        self.store = store
        self.preferences = preferences
        do {
            profiles = try store.load()
        } catch {
            log.error("loading profiles failed: \(error.localizedDescription, privacy: .public)")
            self.error = .keychainUnreadable
        }
        if preferences.demoActive, let demo = DemoAgent.makeProfile() { profiles.append(demo) }
        if activeProfile == nil { preferences.activeProfileID = profiles.first?.id }
        shareActiveAgent()
    }

    var activeProfile: RelayProfile? {
        profiles.first { $0.id == preferences.activeProfileID }
    }

    /// Paired agents, without the demo agent.
    var realProfiles: [RelayProfile] { profiles.filter { !$0.isDemo } }

    /// Something may go to the active agent only with the owner's consent; the demo agent keeps everything on the phone.
    var mayShare: Bool { preferences.aiConsent }

    /// Asks for consent (ConsentView) when it is missing; true when sharing is allowed.
    func requireConsent() -> Bool {
        guard !mayShare else { return true }
        error = .consentRequired
        return false
    }

    // MARK: demo agent

    /// "Try a demo": the offline demo agent becomes the active one (see DemoAgent).
    func startDemo() {
        if !profiles.contains(where: \.isDemo), let demo = DemoAgent.makeProfile() { profiles.append(demo) }
        preferences.demoActive = true
        preferences.onboardingDone = true
        activate(DemoAgent.id)
    }

    /// Removes the demo agent and its chat; real agents are untouched.
    func removeDemo() async {
        let wasActive = activeProfile?.isDemo == true
        profiles.removeAll(where: \.isDemo)
        preferences.demoActive = false
        await ChatStore.shared.deleteChat(DemoAgent.id)
        if wasActive {
            disconnect()
            preferences.activeProfileID = profiles.first?.id
            connect()
        }
        shareActiveAgent()
    }

    func pair(invite: PairingInvite, deviceName: String) async throws {
        var profile = try await DevicePairing.pair(invite: invite, deviceName: deviceName)
        profile.palette = AgentPalette.next(after: profiles.map(\.agentPalette))
        profiles.append(profile)
        try store.save(realProfiles)
        activate(profile.id)
        preferences.onboardingDone = true
        syncPushRegistrations()
    }

    /// Makes `id` the active agent. In the foreground the previous agent's connection stays open (standby).
    func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), id != preferences.activeProfileID || session == nil else { return }
        let previous = session
        session = nil
        preferences.activeProfileID = id
        shareActiveAgent()
        if let previous {
            if isForeground, standingIDs.contains(previous.profile.id) {
                standby[previous.profile.id] = previous
            } else if !isInUse(previous) {
                Task { await previous.stop() }
            }
        }
        connect()
    }

    /// Shows an agent's chat (the active agent's when nil): switches to it and to the chat tab.
    func openChat(_ id: UUID?) {
        if let id, id != activeProfile?.id { activate(id) }
        tab = .chat
        chatRequest = activeProfile?.id
    }

    /// What a `hermescall://` link does (see `DeepLink`). True when a call should start now: only the app's
    /// own widget links; a call link from anywhere else asks first and switches no agent until confirmed.
    func open(_ link: DeepLink) -> Bool {
        switch link {
        case .pair(let text):
            route = .pair(text)
        case .chat(let agent):
            openChat(agent)
        case .call(let agent, let trusted):
            let known = agent.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            guard trusted else {
                route = .confirmCall(known)
                return false
            }
            if let known, known != activeProfile?.id { activate(known) }
            tab = .call
            return true
        case .open:
            break
        }
        return false
    }

    /// "Call" on the confirmation of an outside call link: now the agent may become the active one.
    func confirmCall(_ agent: UUID?) {
        route = nil
        if let agent, agent != activeProfile?.id { activate(agent) }
        tab = .call
    }

    /// The paired agent `step` places after (or before) the active one, wrapping around; nil with one agent.
    func neighbor(_ step: Int) -> RelayProfile? {
        guard profiles.count > 1 else { return nil }
        let current = profiles.firstIndex { $0.id == preferences.activeProfileID } ?? 0
        return profiles[((current + step) % profiles.count + profiles.count) % profiles.count]
    }

    /// The HUD colour, and the name and colour extensions show (widgets, Live Activity).
    private func shareActiveAgent() {
        HUDTheme.shared.apply(activeProfile?.agentPalette ?? .gold)
        PresenceStill.refresh(activeProfile?.agentPalette ?? .gold)
        SharedContainer.defaults.set(activeProfile?.bridgeName ?? RelayProfile.defaultAgentName, forKey: SharedContainer.agentNameKey)
        shareAgents()
    }

    /// Names and colours of the paired agents for the widget's agent picker and the share sheet (no keys).
    private func shareAgents() {
        AgentDirectory.save(profiles.map { AgentInfo(id: $0.id, name: $0.bridgeName, palette: $0.agentPalette.rawValue) },
                            active: activeProfile?.id)
        // "Call Atlas with Hermes Call": Siri learns the agents' names.
        HermesShortcuts.updateAppShortcutParameters()
    }

    func setPalette(_ id: UUID, to palette: AgentPalette) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].palette = palette
        persist()
        shareAgents()
        if id == preferences.activeProfileID { HUDTheme.shared.apply(palette) }
    }

    func rename(_ id: UUID, to label: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        persist()
    }

    func renameAgent(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        profiles[index].bridgeName = trimmed.isEmpty ? RelayProfile.defaultAgentName : trimmed
        persist()
        shareActiveAgent()
    }

    /// Asks the bridge to revoke this phone (best effort), then deletes the local keys.
    func unpair(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        guard !profile.isDemo else { return await removeDemo() }
        await Self.notifyUnpair(profile)
        if preferences.activeProfileID == id { disconnect() }
        if let other = standby.removeValue(forKey: id) { Task { await other.stop() } }
        profiles.removeAll { $0.id == id }
        preferences.pushRegistrations[id.uuidString] = nil
        preferences.alertRegistrations[id.uuidString] = nil
        persist()
        await ChatStore.shared.deleteChat(id)
        if preferences.activeProfileID == id { preferences.activeProfileID = profiles.first?.id }
        shareActiveAgent()
        connect()
    }

    func deleteAllData() async {
        await withTaskGroup(of: Void.self) { group in
            for profile in realProfiles { group.addTask { await Self.notifyUnpair(profile) } }
        }
        await ChatStore.shared.deleteAll()
        ChatSnapshot.clear()
        AgentDirectory.clear()
        ChatBadge.reset()
        disconnect()
        for entry in borrowed.values { await entry.session.stop() }
        for other in standby.values { await other.stop() }
        borrowed = [:]
        standby = [:]
        profiles = []
        do { try store.deleteAll() } catch { lastError = error.localizedDescription }
        await ChatStore.shared.deleteChat(DemoAgent.id)
        preferences.reset()
    }

    /// The agents that keep a connection while the app is on screen: the active one first, then the others in
    /// their order, at most `maxStanding`.
    static func standing(_ profiles: [RelayProfile], active: UUID?, limit: Int = maxStanding) -> [UUID] {
        let real = profiles.filter { !$0.isDemo }
        let first = real.filter { $0.id == active }
        return (first + real.filter { $0.id != active }).prefix(limit).map(\.id)
    }

    private var standingIDs: Set<UUID> { Set(Self.standing(profiles, active: activeProfile?.id)) }

    /// Connects the active agent and, in the foreground, the other standing ones.
    func connect() {
        connectActive()
        guard isForeground else { return }
        let wanted = standingIDs
        for (id, other) in standby where !wanted.contains(id) {
            standby[id] = nil
            if !isInUse(other) { Task { await other.stop() } }
        }
        for profile in profiles where wanted.contains(profile.id) && openSession(for: profile.id) == nil {
            do {
                standby[profile.id] = try startSession(profile)
            } catch {
                log.error("could not connect a standby agent: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func connectActive() {
        guard session == nil, let profile = activeProfile, !profile.isDemo else { return }
        if let waiting = standby.removeValue(forKey: profile.id) ?? borrowed[profile.id]?.session {
            session = waiting
            return
        }
        do {
            session = try startSession(profile)
        } catch {
            self.error = .profileDamaged(agent: profile.bridgeName)
        }
    }

    private func startSession(_ profile: RelayProfile) throws -> RelaySession {
        let session = try makeSession(profile)
        onSessionCreated?(session)
        Task { await session.start() }
        return session
    }

    /// The network came back: try every relay now instead of waiting for the backoff.
    func reconnectNow() {
        guard session != nil else { return connect() }
        for open in [session].compactMap({ $0 }) + Array(standby.values) { Task { await open.reconnectNow() } }
    }

    var isBorrowed: Bool { borrowed.values.contains { $0.session === session } }

    private func isInUse(_ candidate: RelaySession) -> Bool { borrowed.values.contains { $0.session === candidate } }

    /// An open connection to this profile's relay, if the app has one.
    func openSession(for id: UUID) -> RelaySession? {
        if let session, session.profile.id == id { return session }
        return standby[id] ?? borrowed[id]?.session
    }

    /// Stops the active agent's connection (unless borrowed).
    func disconnect() {
        guard let session else { return }
        self.session = nil
        if !isInUse(session) { Task { await session.stop() } }
    }

    /// The app left the screen: only borrowed connections (a call, a push registration) stay open.
    func enterBackground() {
        isForeground = false
        for (id, other) in standby where !isInUse(other) {
            standby[id] = nil
            Task { await other.stop() }
        }
        if !isBorrowed { disconnect() }
    }

    /// A connection to `profile`'s relay (the app's own one when it has one) that stays open
    /// until every borrower has called `releaseSession`.
    func borrowSession(for profile: RelayProfile) throws -> RelaySession {
        guard !profile.isDemo else { throw ProtocolError.notConnected }
        if let entry = borrowed[profile.id] {
            borrowed[profile.id] = (entry.session, entry.users + 1)
            return entry.session
        }
        if profile.id == activeProfile?.id { connectActive() }
        let session = try openSession(for: profile.id) ?? startSession(profile)
        borrowed[profile.id] = (session, 1)
        return session
    }

    func releaseSession(_ session: RelaySession) {
        guard let (id, entry) = borrowed.first(where: { $0.value.session === session }) else { return }
        guard entry.users <= 1 else {
            borrowed[id] = (session, entry.users - 1)
            return
        }
        borrowed[id] = nil
        if session === self.session {
            if !isForeground { disconnect() }
        } else if standby[id] === session {
            if !isForeground {
                standby[id] = nil
                Task { await session.stop() }
            }
        } else {
            Task { await session.stop() }
        }
    }

    private func makeSession(_ profile: RelayProfile) throws -> RelaySession {
        let id = profile.id
        let token = UUID()
        let session = try RelaySession(profile: profile, replayStore: .standard, onStatus: { [weak self] status in
            Task { @MainActor in
                guard let self, self.sessionTokens[id] == token else { return }
                self.statuses[id] = status
                self.connectedAt[id] = status == .connected ? Date() : nil
                if status == .connected, let open = self.openSession(for: id) { self.onConnected?(open) }
            }
        }, onReady: { [weak self] info in
            Task { @MainActor in self?.relayInfo[id] = info }
        }, hello: AppHello.body(appVersion: DiagnosticsView.appVersion), onBridgeHello: { [weak self] info in
            Task { @MainActor in self?.bridgeInfo[id] = info }
        })
        sessionTokens[id] = token
        statuses[id] = .disconnected
        return session
    }

    // MARK: VoIP push registration

    func updatePushToken(_ token: String?) {
        pushToken = token
        syncPushRegistrations()
    }

    /// Chat notifications use a separate (alert) APNs token.
    func updateAlertToken(_ token: String?) {
        alertToken = token
        syncPushRegistrations()
    }

    /// Registers the current push tokens (VoIP for calls, alert for chat) with every relay that does not have them yet.
    func syncPushRegistrations(environment: String = PushEnvironment.current) {
        if pushToken == nil { preferences.pushRegistrations = [:] }
        if alertToken == nil { preferences.alertRegistrations = [:] }
        for profile in realProfiles where !registeringPush.contains(profile.id) {
            let voip = pushToken.map { "\(environment):\($0)" }
            let alert = alertToken.map { "\(environment):\($0)" }
            let needsVoip = voip != nil && preferences.pushRegistrations[profile.id.uuidString] != voip
            let needsAlert = alert != nil && preferences.alertRegistrations[profile.id.uuidString] != alert
            guard needsVoip || needsAlert else { continue }
            registeringPush.insert(profile.id)
            Task {
                await registerPush(profile, environment: environment, voip: needsVoip ? pushToken : nil,
                                   alert: needsAlert ? alertToken : nil)
            }
        }
    }

    private func registerPush(_ profile: RelayProfile, environment: String, voip: String?, alert: String?) async {
        defer {
            registeringPush.remove(profile.id)
            if (voip != nil && pushToken != voip) || (alert != nil && alertToken != alert) { syncPushRegistrations() }
        }
        guard let session = try? borrowSession(for: profile) else { return }
        defer { releaseSession(session) }
        for (kind, token) in [("voip", voip), ("alert", alert)] {
            guard let token else { continue }
            do {
                _ = try await session.request(["t": "register_push", "token": .string(token), "env": .string(environment),
                                               "kind": .string(kind)])
                guard profiles.contains(where: { $0.id == profile.id }) else { return }
                if kind == "voip" {
                    preferences.pushRegistrations[profile.id.uuidString] = "\(environment):\(token)"
                } else {
                    preferences.alertRegistrations[profile.id.uuidString] = "\(environment):\(token)"
                }
                log.info("\(kind, privacy: .public) push token registered with a relay")
            } catch {
                log.error("push registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Best effort: an unreachable relay must not block local deletion.
    private nonisolated static func notifyUnpair(_ profile: RelayProfile) async {
        guard let session = try? RelaySession(profile: profile, replayStore: .standard) else { return }
        if (try? await session.waitUntilConnected(timeout: 5)) != nil {
            try? await session.send(["type": "unpair"])
            try? await Task.sleep(for: .milliseconds(300))
        }
        await session.stop()
    }

    private func persist() {
        do { try store.save(realProfiles) } catch { lastError = error.localizedDescription }
    }
}
