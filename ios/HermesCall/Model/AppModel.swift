import Foundation
import HermesCallCore
import os

enum AppTab: Hashable { case call, chat }

/// App state: paired relay profiles, the active relay connection and pairing.
@MainActor @Observable
final class AppModel {
    private(set) var profiles: [RelayProfile] = []
    private(set) var relayStatus: RelaySession.Status = .disconnected
    private(set) var session: RelaySession?
    private(set) var pushToken: String?
    var lastError: String?
    /// Lets the call coordinator listen to every relay connection the app opens.
    var onSessionCreated: ((RelaySession) -> Void)?
    /// A relay connection (the app's own or a borrowed one) is up: fetch mail, resend the outbox.
    var onConnected: ((RelaySession) -> Void)?
    /// Which tab is shown; notifications and deep links switch to the chat.
    var tab: AppTab = .call
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
            lastError = "Could not read your saved relays from the Keychain."
        }
        if activeProfile == nil { preferences.activeProfileID = profiles.first?.id }
        shareActiveAgent()
    }

    var activeProfile: RelayProfile? {
        profiles.first { $0.id == preferences.activeProfileID }
    }

    func pair(invite: PairingInvite, deviceName: String) async throws {
        var profile = try await DevicePairing.pair(invite: invite, deviceName: deviceName)
        profile.palette = AgentPalette.next(after: profiles.map(\.agentPalette))
        profiles.append(profile)
        try store.save(profiles)
        activate(profile.id)
        preferences.onboardingDone = true
        syncPushRegistrations()
    }

    func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        preferences.activeProfileID = id
        shareActiveAgent()
        disconnect()
        connect()
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
        await Self.notifyUnpair(profile)
        if preferences.activeProfileID == id { disconnect() }
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
            for profile in profiles { group.addTask { await Self.notifyUnpair(profile) } }
        }
        await ChatStore.shared.deleteAll()
        ChatSnapshot.clear()
        AgentDirectory.clear()
        ChatBadge.reset()
        disconnect()
        for entry in borrowed.values { await entry.session.stop() }
        borrowed = [:]
        profiles = []
        do { try store.deleteAll() } catch { lastError = error.localizedDescription }
        preferences.reset()
    }

    func connect() {
        guard session == nil, let profile = activeProfile else { return }
        if let shared = borrowed[profile.id]?.session {
            session = shared
            return
        }
        do {
            let session = try makeSession(profile)
            self.session = session
            onSessionCreated?(session)
            Task { await session.start() }
        } catch {
            lastError = "This relay profile is damaged. Remove it and pair again."
        }
    }

    var isBorrowed: Bool { borrowed.values.contains { $0.session === session } }

    /// An open connection to this profile's relay, if the app has one.
    func openSession(for id: UUID) -> RelaySession? {
        if let session, session.profile.id == id { return session }
        return borrowed[id]?.session
    }

    func disconnect() {
        guard let session else { return }
        self.session = nil
        relayStatus = .disconnected
        if !borrowed.values.contains(where: { $0.session === session }) {
            Task { await session.stop() }
        }
    }

    /// A connection to `profile`'s relay (the app's own one for the active relay) that stays open
    /// until every borrower has called `releaseSession`.
    func borrowSession(for profile: RelayProfile) throws -> RelaySession {
        if let entry = borrowed[profile.id] {
            borrowed[profile.id] = (entry.session, entry.users + 1)
            return entry.session
        }
        let session: RelaySession
        if profile.id == activeProfile?.id {
            connect()
            guard let active = self.session else { throw ProtocolError.notConnected }
            session = active
        } else {
            session = try makeSession(profile)
            onSessionCreated?(session)
            Task { await session.start() }
        }
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
        if session !== self.session {
            Task { await session.stop() }
        } else if !isForeground {
            disconnect()
        }
    }

    private func makeSession(_ profile: RelayProfile) throws -> RelaySession {
        let id = profile.id
        return try RelaySession(profile: profile, replayStore: .standard) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if status == .connected, let open = self.openSession(for: id) { self.onConnected?(open) }
                guard self.session?.profile.id == id else { return }
                self.relayStatus = status
            }
        }
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
        for profile in profiles where !registeringPush.contains(profile.id) {
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
        do { try store.save(profiles) } catch { lastError = error.localizedDescription }
    }
}
