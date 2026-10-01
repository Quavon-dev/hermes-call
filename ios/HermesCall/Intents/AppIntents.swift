import AppIntents
import HermesCallCore

/// Lets App Intents (Siri, Shortcuts, widgets) reach the app's models; they run in the app's process.
@MainActor
final class AppServices {
    static let shared = AppServices()
    private(set) var app: AppModel?
    private(set) var chat: ChatModel?
    private(set) var calls: CallCoordinator?

    func configure(app: AppModel, chat: ChatModel, calls: CallCoordinator) {
        self.app = app
        self.chat = chat
        self.calls = calls
        CallAgentIntent.handler = { [weak app, weak calls] agent in
            if let agent, agent != app?.activeProfile?.id { app?.activate(agent) }
            app?.tab = .call
            await calls?.startCall()
        }
        OpenChatIntent.handler = { [weak app] agent in app?.openChat(agent) }
        StopAgentIntent.handler = { [weak app, weak chat, weak calls] agent in
            guard let app, let chat else { return .notPaired }
            return await AgentStop.fromIntent(app: app, chat: chat, calls: calls, agent: agent)
        }
    }
}

struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Agent"
    static let description = IntentDescription("Sends a message to your agent in Hermes Call and reads the answer if it comes quickly.")
    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$agent) \(\.$message)") }

    @Parameter(title: "Message", requestValueDialog: "What should I ask?")
    var message: String

    /// nil: the active agent.
    @Parameter(title: "Agent")
    var agent: AgentEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let chat = AppServices.shared.chat, let app = AppServices.shared.app, app.activeProfile != nil else {
            return .result(value: "", dialog: "Pair Hermes Call with your bridge first.")
        }
        if let agent, agent.id != app.activeProfile?.id { app.activate(agent.id) }
        guard app.activeProfile?.isDemo == true || app.mayShare else {
            return .result(value: "", dialog: "Open Hermes Call and allow sharing with your agent first.")
        }
        let reply = await chat.ask(message)
        switch reply {
        case .answered(let text): return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        case .sent: return .result(value: "", dialog: "Sent. The answer will arrive in Hermes Call.")
        case .failed: return .result(value: "", dialog: "Your relay could not be reached. The message waits in the outbox.")
        }
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAgentIntent(), phrases: ["Ask \(.applicationName)", "Message \(.applicationName)",
                                                        "Ask \(\.$agent) in \(.applicationName)"],
                    shortTitle: "Ask", systemImageName: "bubble.left.fill")
        AppShortcut(intent: CallAgentIntent(), phrases: ["Call \(.applicationName)", "Start a \(.applicationName) call",
                                                         "Call \(\.$agent) with \(.applicationName)"],
                    shortTitle: "Call", systemImageName: "phone.fill")
        AppShortcut(intent: StopAgentIntent(), phrases: ["Stop \(.applicationName)", "Stop my agent in \(.applicationName)",
                                                         "Stop \(\.$agent) in \(.applicationName)"],
                    shortTitle: "Stop", systemImageName: "stop.circle.fill")
        AppShortcut(intent: OpenChatIntent(), phrases: ["Open \(.applicationName) chat", "Open the chat with \(\.$agent) in \(.applicationName)"],
                    shortTitle: "Chat", systemImageName: "bubble.left.and.bubble.right.fill")
    }
}

/// Focus › Hermes Call: which agents may notify while this Focus is on (none chosen: all may). Chat
/// messages, questions and place reminders carry their agent's id as `filterCriteria`.
struct AgentFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Agents that may notify"
    static let description = IntentDescription("Choose which agents' messages and questions come through during this Focus.")

    @Parameter(title: "Agents")
    var agents: [AgentEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (agents ?? []).map(\.name)
        return DisplayRepresentation(title: names.isEmpty ? "All agents" : "\(names.joined(separator: ", "))")
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: Self.predicate(for: agents?.map(\.id)))
    }

    /// nil lets every agent through.
    static func predicate(for ids: [UUID]?) -> NSPredicate? {
        guard let ids, !ids.isEmpty else { return nil }
        return NSPredicate(format: "SELF IN %@", ids.map(\.uuidString))
    }

    func perform() async throws -> some IntentResult { .result() }
}
