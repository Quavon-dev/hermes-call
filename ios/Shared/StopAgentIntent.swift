import AppIntents
import Foundation

/// "Stop Atlas": the emergency stop (docs/protocol.md, "Stop"). Siri, Shortcuts, the Action button and the
/// Control Center control. Compiled into the app and the widget extension; as a `LiveActivityIntent` the
/// system runs it in the app's process (in the background, no app UI), where `handler` is set at launch.
struct StopAgentIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Agent"
    static let description = IntentDescription("Stops what your agent is doing right now (the active one unless you pick one). The conversation stays.")
    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$agent)") }

    /// nil: the active agent.
    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {}

    init(agent: AgentEntity?) {
        self.agent = agent
    }

    enum Outcome: Sendable {
        /// The bridge has it.
        case requested
        /// Stored; it goes out when the relay is reachable.
        case queued
        case notPaired
        case needsConsent
    }

    @MainActor static var handler: (@MainActor (UUID?) async -> Outcome)?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = Self.handler else { return .result(dialog: "Open Hermes Call once, then try again.") }
        switch await handler(agent?.id) {
        case .requested: return .result(dialog: "Stop requested.")
        case .queued: return .result(dialog: "Stop requested. It goes out as soon as your relay is reachable.")
        case .notPaired: return .result(dialog: "Pair Hermes Call with your bridge first.")
        case .needsConsent: return .result(dialog: "Open Hermes Call and allow sharing with your agent first.")
        }
    }
}
