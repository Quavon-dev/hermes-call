import Foundation

public struct SlashCommand: Sendable, Equatable, Identifiable {
    public let name: String
    public let summary: String
    public let symbol: String
    public let arguments: String?
    public let aliases: [String]
    public let runsAtOnce: Bool

    public init(_ name: String, _ summary: String, symbol: String, arguments: String? = nil, aliases: [String] = [],
                runsAtOnce: Bool = false) {
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.arguments = arguments
        self.aliases = aliases
        self.runsAtOnce = runsAtOnce
    }

    public var id: String { name }
    public var text: String { "/" + name }

    public static let new = SlashCommand("new", "Start a new session", symbol: "plus.bubble", arguments: "[name]", aliases: ["reset"],
                                         runsAtOnce: true)
    public static let retry = SlashCommand("retry", "Send your last message again", symbol: "arrow.clockwise", runsAtOnce: true)
    public static let undo = SlashCommand("undo", "Back up one turn and ask again", symbol: "arrow.uturn.backward", arguments: "[N]",
                                          runsAtOnce: true)
    public static let stop = SlashCommand("stop", "Stop the running task", symbol: "stop.circle", runsAtOnce: true)

    public static let all: [SlashCommand] = [
        new, retry, undo, stop,
        SlashCommand("status", "Session, model, tokens and context", symbol: "info.circle", runsAtOnce: true),
        SlashCommand("agents", "Active agents and running tasks", symbol: "person.2", aliases: ["tasks"], runsAtOnce: true),
        SlashCommand("btw", "Side question without interrupting", symbol: "questionmark.bubble", arguments: "<question>"),
        SlashCommand("steer", "Steer after the next tool call", symbol: "steeringwheel", arguments: "<prompt>", aliases: ["s"]),
        SlashCommand("queue", "Queue a prompt for the next turn", symbol: "list.bullet", arguments: "[prompt|list|clear]",
                     aliases: ["q"]),
        SlashCommand("bg", "Run a prompt in a background session", symbol: "square.stack.3d.up", arguments: "<prompt>"),
        SlashCommand("compress", "Compress the conversation context", symbol: "rectangle.compress.vertical",
                     arguments: "[here N|focus topic]", aliases: ["compact"], runsAtOnce: true),
        SlashCommand("context", "Context window usage", symbol: "gauge.with.dots.needle.33percent", aliases: ["ctx"],
                     runsAtOnce: true),
        SlashCommand("usage", "Token usage and rate limits", symbol: "chart.bar", runsAtOnce: true),
        SlashCommand("insights", "Usage insights", symbol: "chart.line.uptrend.xyaxis", arguments: "[days]", runsAtOnce: true),
        SlashCommand("model", "Switch the model", symbol: "cpu", arguments: "[model] [--reasoning level]"),
        SlashCommand("reasoning", "Reasoning effort and display", symbol: "brain", arguments: "[level|show|hide]"),
        SlashCommand("fast", "Fast mode", symbol: "hare", arguments: "[normal|fast|auto|status]"),
        SlashCommand("personality", "Set a personality", symbol: "theatermasks", arguments: "[name]"),
        SlashCommand("title", "Name this session", symbol: "textformat", arguments: "[name]"),
        SlashCommand("sessions", "Browse and resume sessions", symbol: "clock", runsAtOnce: true),
        SlashCommand("resume", "Resume a named session", symbol: "play.circle", arguments: "[name]"),
        SlashCommand("branch", "Branch the current session", symbol: "arrow.triangle.branch", arguments: "[name]", aliases: ["fork"]),
        SlashCommand("save", "Export the conversation", symbol: "square.and.arrow.down", arguments: "<json|md|html> [file]"),
        SlashCommand("goal", "Set a standing goal", symbol: "target", arguments: "[text|show|pause|resume|clear]"),
        SlashCommand("subgoal", "Extra criteria for the goal", symbol: "scope", arguments: "[text|remove N|clear]"),
        SlashCommand("plan", "Write a plan without executing", symbol: "list.bullet.clipboard", arguments: "[task]"),
        SlashCommand("review", "Subagent reviews the recent work", symbol: "checkmark.seal", arguments: "[instructions]"),
        SlashCommand("refine", "Save lessons to memory and skills", symbol: "wand.and.stars", arguments: "[focus]"),
        SlashCommand("learn", "Learn a reusable skill", symbol: "graduationcap", arguments: "<what to learn from>"),
        SlashCommand("loop", "Re-run a prompt on an interval", symbol: "repeat", arguments: "[interval] <prompt>",
                     aliases: ["proactive"]),
        SlashCommand("heartbeat", "Recurring prompt when idle", symbol: "waveform.path.ecg", arguments: "[every <interval> <prompt>]",
                     aliases: ["hb"]),
        SlashCommand("moa", "One prompt through Mixture of Agents", symbol: "square.3.layers.3d", arguments: "<prompt>"),
        SlashCommand("pause", "Pause new work globally", symbol: "pause.circle", arguments: "[reason|off]"),
        SlashCommand("rollback", "List or restore file checkpoints", symbol: "clock.arrow.circlepath", arguments: "[number]"),
        SlashCommand("diff", "Git changes in the working directory", symbol: "plusminus", arguments: "[staged|all] [--stat]"),
        SlashCommand("init", "Generate AGENTS.md from a repo scan", symbol: "doc.badge.plus", arguments: "[notes]"),
        SlashCommand("memory", "Review pending memory writes", symbol: "memorychip", arguments: "[pending|approve|reject]"),
        SlashCommand("busy", "How messages behave while busy", symbol: "hourglass", arguments: "[queue|steer|interrupt]"),
        SlashCommand("voice", "Voice mode", symbol: "waveform", arguments: "[on|off|tts|status]"),
        SlashCommand("approvals", "Command approval mode", symbol: "hand.raised", arguments: "[manual|smart|off]"),
        SlashCommand("yolo", "Skip all command approvals", symbol: "exclamationmark.triangle"),
        SlashCommand("footer", "Runtime footer on replies", symbol: "text.below.photo", arguments: "[on|off|status]"),
        SlashCommand("suggestions", "Suggested automations", symbol: "lightbulb", arguments: "[accept|dismiss N]", aliases: ["suggest"]),
        SlashCommand("blueprint", "Automation from a blueprint", symbol: "square.grid.2x2", arguments: "[name]", aliases: ["bp"]),
        SlashCommand("bundles", "Skill bundles", symbol: "shippingbox", runsAtOnce: true),
        SlashCommand("curator", "Background skill maintenance", symbol: "books.vertical", arguments: "[status|run|list-archived]"),
        SlashCommand("kanban", "Collaboration board", symbol: "rectangle.split.3x1", arguments: "[subcommand]"),
        SlashCommand("profile", "Active profile and home", symbol: "person.text.rectangle", runsAtOnce: true),
        SlashCommand("whoami", "Your command access", symbol: "person.crop.circle", runsAtOnce: true),
        SlashCommand("sethome", "Make this chat the home channel", symbol: "house", aliases: ["set-home"]),
        SlashCommand("platform", "Pause or resume a platform", symbol: "switch.2", arguments: "<pause|resume|list> [name]"),
        SlashCommand("egress", "Docker egress proxy status", symbol: "network", runsAtOnce: true),
        SlashCommand("codex-runtime", "Codex app-server runtime", symbol: "gearshape.2", arguments: "[auto|codex_app_server]"),
        SlashCommand("reload-mcp", "Reload MCP servers", symbol: "arrow.triangle.2.circlepath"),
        SlashCommand("reload-skills", "Re-scan installed skills", symbol: "arrow.clockwise.circle"),
        SlashCommand("commands", "Every command and skill", symbol: "command", arguments: "[page]", runsAtOnce: true),
        SlashCommand("help", "Available commands", symbol: "questionmark.circle", arguments: "[skills|filter]", runsAtOnce: true),
        SlashCommand("version", "Hermes version", symbol: "number", aliases: ["v"], runsAtOnce: true),
        SlashCommand("login", "Sign in with a Nous account", symbol: "person.badge.key"),
        SlashCommand("topup", "Nous balance and billing", symbol: "creditcard", runsAtOnce: true),
        SlashCommand("update", "Update Hermes Agent", symbol: "arrow.down.circle"),
        SlashCommand("restart", "Restart the gateway", symbol: "power"),
        SlashCommand("debug", "Upload a debug report", symbol: "ladybug", arguments: "[nous|local]"),
    ]

    public static func suggestions(for draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let prefix = draft.dropFirst().lowercased()
        return all.filter { command in command.name.hasPrefix(prefix) || command.aliases.contains { $0.hasPrefix(prefix) } }
    }
}
