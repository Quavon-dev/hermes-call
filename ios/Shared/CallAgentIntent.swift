import AppIntents
import Foundation
import HermesCallCore

/// A paired agent, for the widget's agent picker, the intents ("Call Atlas") and the Focus filter (read from
/// the app group: names and colours only, no keys).
struct AgentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Agent" }
    static var defaultQuery: AgentQuery { AgentQuery() }

    let id: UUID
    let name: String

    init(_ agent: AgentInfo) {
        id = agent.id
        name = agent.name
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AgentQuery: EnumerableEntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [AgentEntity] {
        AgentDirectory.agents().filter { identifiers.contains($0.id) }.map(AgentEntity.init)
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        AgentDirectory.agents().map(AgentEntity.init)
    }

    func allEntities() async throws -> [AgentEntity] {
        AgentDirectory.agents().map(AgentEntity.init)
    }

    /// "Call Atlas": Siri matches the spoken name.
    func entities(matching string: String) async throws -> [AgentEntity] {
        AgentDirectory.agents().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(AgentEntity.init)
    }
}

/// "Call Atlas": Siri, Shortcuts, the Control Center control, the Action button and the widget.
/// Compiled into the app and the widget extension; `openAppWhenRun` makes the system run it in
/// the app, where `handler` is set at launch (in the extension it stays nil).
struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Agent"
    static let description = IntentDescription("Starts a voice call with your agent (the active one unless you pick one).")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary { Summary("Call \(\.$agent)") }

    /// nil: the active agent.
    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {}

    init(agent: AgentEntity?) {
        self.agent = agent
    }

    @MainActor static var handler: (@MainActor (UUID?) async -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        await Self.handler?(agent?.id)
        return .result()
    }
}

/// Opens the chat (of one agent, or the active one). Compiled into the app and the widget extension.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens the chat with your agent (the active one unless you pick one).")
    static let openAppWhenRun = true
    static var parameterSummary: some ParameterSummary { Summary("Open the chat with \(\.$agent)") }

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {}

    init(agent: AgentEntity?) {
        self.agent = agent
    }

    @MainActor static var handler: (@MainActor (UUID?) -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?(agent?.id)
        return .result()
    }
}

/// The chat widget's settings: which agent it shows.
struct ChatWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent"
    static let description = IntentDescription("Choose the agent this widget shows.")

    /// nil: whichever agent is active in the app.
    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {}
}
