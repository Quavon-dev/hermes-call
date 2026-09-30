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
        CallAgentIntent.handler = { [weak app, weak calls] in
            app?.tab = .call
            await calls?.startCall()
        }
    }
}

struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription("Sends a message to your agent in Hermes Call and reads the answer if it comes quickly.")

    @Parameter(title: "Message", requestValueDialog: "What should I ask?")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let chat = AppServices.shared.chat, AppServices.shared.app?.activeProfile != nil else {
            return .result(value: "", dialog: "Pair Hermes Call with your bridge first.")
        }
        let reply = await chat.ask(message)
        switch reply {
        case .answered(let text): return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        case .sent: return .result(value: "", dialog: "Sent. The answer will arrive in Hermes Call.")
        case .failed: return .result(value: "", dialog: "Your relay could not be reached. The message waits in the outbox.")
        }
    }
}

struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Hermes Chat"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.app?.tab = .chat
        return .result()
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAgentIntent(), phrases: ["Ask \(.applicationName)", "Message \(.applicationName)"],
                    shortTitle: "Ask", systemImageName: "bubble.left.fill")
        AppShortcut(intent: CallAgentIntent(), phrases: ["Call \(.applicationName)", "Start a \(.applicationName) call"],
                    shortTitle: "Call", systemImageName: "phone.fill")
        AppShortcut(intent: OpenChatIntent(), phrases: ["Open \(.applicationName) chat"],
                    shortTitle: "Chat", systemImageName: "bubble.left.and.bubble.right.fill")
    }
}
