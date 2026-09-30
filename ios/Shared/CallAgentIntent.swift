import AppIntents

/// "Call Hermes": Siri, Shortcuts, the Control Center control and the Action button.
/// Compiled into the app and the widget extension; `openAppWhenRun` makes the system run it in
/// the app, where `handler` is set at launch (in the extension it stays nil).
struct CallAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Hermes"
    static let description = IntentDescription("Starts a voice call with your agent.")
    static let openAppWhenRun = true

    @MainActor static var handler: (@MainActor () async -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        await Self.handler?()
        return .result()
    }
}
