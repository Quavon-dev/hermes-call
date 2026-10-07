import Foundation

public struct SlashCommand: Sendable, Equatable, Identifiable {
    public let name: String
    public let summary: String
    public let symbol: String
    public let takesArgument: Bool

    public var id: String { name }
    public var text: String { "/" + name }

    public static let new = SlashCommand(name: "new", summary: "Start a new session", symbol: "plus.bubble", takesArgument: false)
    public static let retry = SlashCommand(name: "retry", summary: "Answer your last message again", symbol: "arrow.clockwise",
                                           takesArgument: false)
    public static let undo = SlashCommand(name: "undo", summary: "Forget the last exchange", symbol: "arrow.uturn.backward",
                                          takesArgument: false)
    public static let stop = SlashCommand(name: "stop", summary: "Stop the running task", symbol: "stop.circle", takesArgument: false)
    public static let all: [SlashCommand] = [
        new, retry, undo,
        SlashCommand(name: "compress", summary: "Shorten the session's context", symbol: "rectangle.compress.vertical",
                     takesArgument: false),
        SlashCommand(name: "usage", summary: "Tokens used in this session", symbol: "chart.bar", takesArgument: false),
        SlashCommand(name: "model", summary: "Show or switch the model", symbol: "cpu", takesArgument: true),
        SlashCommand(name: "help", summary: "Every command Hermes knows", symbol: "questionmark.circle", takesArgument: false),
        stop,
    ]

    public static func suggestions(for draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let prefix = draft.dropFirst().lowercased()
        return all.filter { $0.name.hasPrefix(prefix) }
    }
}
