import ActivityKit
import Foundation
import HermesCallCore
import os

/// The agent's progress on its current turn (bridge `task`, docs/protocol.md "Tasks"): the presence's
/// tasks ring and a Live Activity. While the app runs it updates the activity itself; when it is
/// suspended the bridge pushes updates through the relay (only step counts and, if the owner allows,
/// the step's name).
@MainActor @Observable
final class TaskActivityModel {
    /// The newest turn of the active agent, until a few seconds after it ended.
    private(set) var current: TaskUpdate?
    /// Its agent (a task from another paired agent shows in the Live Activity only).
    private(set) var currentProfile: UUID?
    private(set) var trail = TaskTrail()

    static let lingerAfterEnd: Duration = .seconds(4)
    /// A running task without news for this long is treated as over (a lost end message). The bridge
    /// itself ends a turn after 10 minutes without events and sends `done`; this is that plus a margin.
    static let staleAfter: TimeInterval = 11 * 60

    private let app: AppModel
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "tasks")
    private var clearTask: Task<Void, Never>?
    private var activity: Activity<HermesTaskAttributes>?
    private var tokenWatch: Task<Void, Never>?
    private var startTokenWatch: Task<Void, Never>?
    private var adoptWatch: Task<Void, Never>?
    /// Activity changes run one after another, so a late update can never overtake the end.
    private var activityChain: Task<Void, Never>?
    /// The running activity's push token; registered only with the relay of the agent whose task it shows.
    private var activityToken: String?
    /// Relay profile id → activity push token last registered there.
    private var registeredTokens: [UUID: String] = [:]
    private var startToken: String?
    private var registeredStartTokens: [UUID: String] = [:]

    init(app: AppModel) {
        self.app = app
        // A leftover activity from a previous run (the app was killed mid-task) is adopted; so is one a relay
        // started by push while the app was suspended.
        if let existing = Activity<HermesTaskAttributes>.activities.first { adopt(existing) }
        adoptWatch = Task { [weak self] in
            for await started in Activity<HermesTaskAttributes>.activityUpdates {
                self?.adopt(started)
            }
        }
        watchStartToken()
    }

    private func adopt(_ started: Activity<HermesTaskAttributes>) {
        guard started.id != activity?.id else { return }
        let older = activity?.id
        activity = started
        watchToken(started)
        if let older { enqueue { await Self.change(older, to: nil, end: true) } }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = activityChain
        activityChain = Task {
            await previous?.value
            await work()
        }
    }

    nonisolated static func handles(_ message: [String: JSON]) -> Bool { message["type"]?.string == "task" }

    // MARK: incoming

    func receive(_ body: [String: JSON], from session: RelaySession) {
        let mailID = body["mail_id"]?.string
        if let mailID { Task { try? await session.ackMail([mailID]) } }
        guard let update = TaskUpdate.parse(body) else { return log.error("bad task update ignored") }
        show(update, profile: session.profile.id, agentName: session.profile.bridgeName)
    }

    private func show(_ update: TaskUpdate, profile: UUID, agentName: String) {
        // Only the newest turn matters; a late message of an older turn is dropped.
        if let current, currentProfile == profile, current.turnID != update.turnID, update.startedAt < current.startedAt { return }
        if let current, currentProfile == profile, current.turnID == update.turnID, current.state != .running { return }
        if currentProfile != profile { trail.clear() }
        current = update
        currentProfile = profile
        trail.record(update)
        clearTask?.cancel()
        enqueue { await self.showActivity(update, profile: profile, agentName: agentName) }
        // Ended: linger briefly. Running: if the end never arrives (lost message), give up after `staleAfter`.
        let delay: Duration = update.state == .running ? .seconds(Self.staleAfter) : Self.lingerAfterEnd
        clearTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.current?.turnID == update.turnID else { return }
            self.current = nil
            self.trail.clear()
            if update.state == .running, let id = self.activity?.id {
                self.activity = nil
                self.enqueue { await Self.change(id, to: nil, end: true) }
            }
        }
    }

    #if DEBUG
    /// `-TaskDemo YES`: a fake five-step task a few seconds after launch (simulator screenshots).
    func runDemoIfRequested() {
        guard UserDefaults.standard.bool(forKey: "TaskDemo"), let profile = app.activeProfile else { return }
        let started = Int64(Date().timeIntervalSince1970 * 1000)
        let steps = [("web_search", "Searching the web", "swift concurrency actor reentrancy"),
                     ("web_extract", "Reading pages", "https://www.swift.org/documentation/concurrency/"),
                     ("terminal", "Running a command", "cd ~/projects/app && swift test --filter ActorTests"),
                     ("read_file", "Working on files", "Sources/App/Store.swift"),
                     ("terminal", "Running a command", "git diff --stat && git commit -am 'Fix reentrancy'")]
        Task {
            try? await Task.sleep(for: .seconds(3))
            for (index, step) in steps.enumerated() {
                show(TaskUpdate(turnID: "demo", step: index + 1, total: steps.count, tool: step.0, label: step.1, preview: step.2,
                                state: .running, startedAt: started), profile: profile.id, agentName: profile.bridgeName)
                try? await Task.sleep(for: .seconds(4))
            }
            show(TaskUpdate(turnID: "demo", step: steps.count, total: steps.count, tool: "", label: "Done", preview: nil,
                            state: .done, startedAt: started), profile: profile.id, agentName: profile.bridgeName)
        }
    }
    #endif

    /// For the presence: the task of the agent on screen.
    var activeTask: TaskUpdate? {
        guard currentProfile == app.activeProfile?.id else { return nil }
        return current
    }

    var activeTrail: [TaskUpdate] { activeTask == nil ? [] : trail.steps }

    // MARK: Live Activity

    private func showActivity(_ update: TaskUpdate, profile: UUID, agentName: String) async {
        // The Lock Screen names the step only when the owner allowed it (same rule as pushed updates).
        let state = update.contentState(details: app.preferences.taskDetailsOnLockScreen)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        if update.state != .running {
            guard let id = activity?.id else { return }
            activity = nil
            await Self.change(id, to: content, end: true)
            return
        }
        if let running = activity, running.activityState == .active {
            // An activity names its agent for good: another agent's task gets its own.
            if running.attributes.agentID == nil || running.attributes.agentID == profile {
                await Self.change(running.id, to: content, end: false)
                return
            }
            activity = nil
            await Self.change(running.id, to: nil, end: true)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let palette = app.profiles.first { $0.id == profile }?.agentPalette ?? .gold
        let attributes = HermesTaskAttributes(agentID: profile, agentName: agentName, palette: palette.rawValue)
        do {
            let started = try Activity.request(attributes: attributes, content: content, pushType: .token)
            activity = started
            watchToken(started)
        } catch {
            log.error("live activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Updates or ends an activity by id (looked up here: `Activity` is not Sendable across actors).
    private nonisolated static func change(_ id: String, to content: ActivityContent<TaskContentState>?, end: Bool) async {
        guard let activity = Activity<HermesTaskAttributes>.activities.first(where: { $0.id == id }) else { return }
        if end {
            await activity.end(content, dismissalPolicy: content == nil ? .immediate : .after(Date().addingTimeInterval(10 * 60)))
        } else if let content {
            await activity.update(content)
        }
    }

    /// Each activity has its own push token; the relays need it to update the activity while the app sleeps.
    private func watchToken(_ activity: Activity<HermesTaskAttributes>) {
        tokenWatch?.cancel()
        tokenWatch = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                self.activityToken = data.hex
                self.registeredTokens = [:]
                if let owner = self.currentProfile, let session = self.app.openSession(for: owner) {
                    await self.register(token: data.hex, kind: "liveactivity", only: session)
                }
            }
        }
    }

    /// Push-to-start (iOS 17.2+): lets a relay start the activity when a task begins while the app is closed.
    private func watchStartToken() {
        startTokenWatch = Task { [weak self] in
            for await data in Activity<HermesTaskAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.startToken = data.hex
                await self.register(token: data.hex, kind: "liveactivity_start")
            }
        }
    }

    /// A relay came online: give it the tokens it does not have yet, and the owner's detail preference.
    func connected(_ session: RelaySession) {
        let profile = session.profile.id
        Task {
            // A relay may have restarted and lost them: register again on every connect.
            registeredStartTokens[profile] = nil
            registeredTokens[profile] = nil
            if let startToken { await register(token: startToken, kind: "liveactivity_start", only: session) }
            if let activityToken, currentProfile == profile {
                await register(token: activityToken, kind: "liveactivity", only: session)
            }
            await sendPreferences(to: session)
        }
    }

    private func register(token: String, kind: String, only: RelaySession? = nil) async {
        let profiles = only.map { [$0.profile] } ?? app.profiles
        for profile in profiles {
            let known = kind == "liveactivity" ? registeredTokens[profile.id] : registeredStartTokens[profile.id]
            guard known != token, let session = app.openSession(for: profile.id) ?? only else { continue }
            do {
                _ = try await session.request(["t": "register_push", "token": .string(token), "env": .string(PushEnvironment.current),
                                               "kind": .string(kind)])
                if kind == "liveactivity" { registeredTokens[profile.id] = token } else { registeredStartTokens[profile.id] = token }
            } catch let error as ProtocolError where error.isUnsupported {
                log.notice("\(kind, privacy: .public) tokens: this relay does not support them")
            } catch {
                log.error("\(kind, privacy: .public) token not registered: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: preferences

    /// Tells every connected bridge whether pushed Live Activity updates may name the step.
    func sendPreferences() {
        for profile in app.profiles {
            guard let session = app.openSession(for: profile.id) else { continue }
            Task { await sendPreferences(to: session) }
        }
    }

    private func sendPreferences(to session: RelaySession) async {
        do {
            try await session.send(["type": "task_prefs", "details": .bool(app.preferences.taskDetailsOnLockScreen)])
        } catch {
            log.error("task preferences not sent: \(String(describing: error), privacy: .public)")
        }
    }

    /// "Delete all data": end any activity.
    func endAll() async {
        for activity in Activity<HermesTaskAttributes>.activities { await Self.change(activity.id, to: nil, end: true) }
        activity = nil
        current = nil
        trail.clear()
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
