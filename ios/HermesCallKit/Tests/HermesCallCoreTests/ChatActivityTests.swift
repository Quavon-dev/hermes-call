import Foundation
import Testing
@testable import HermesCallCore

struct ChatActivityTests {
    @Test func slashSuggestionsFollowTheTypedPrefix() {
        #expect(SlashCommand.suggestions(for: "/").count == SlashCommand.all.count)
        #expect(SlashCommand.suggestions(for: "/U").map(\.name) == ["undo", "usage"])
        #expect(SlashCommand.suggestions(for: "/new").map(\.name) == ["new"])
        #expect(SlashCommand.suggestions(for: "/model gpt").isEmpty)
        #expect(SlashCommand.suggestions(for: "hello /new").isEmpty)
        #expect(SlashCommand.suggestions(for: "/zzz").isEmpty)
        #expect(SlashCommand.new.text == "/new")
    }

    private func update(_ step: Int, _ tool: String, turn: String = "t1", state: TaskContentState.State = .running) -> TaskUpdate {
        TaskUpdate(turnID: turn, step: step, total: nil, tool: tool, label: tool, preview: nil, state: state, startedAt: 1)
    }

    @Test func trailKeepsOneEntryPerStepAndEndsTheLast() {
        var trail = TaskTrail()
        trail.record(update(1, "web_search"))
        trail.record(update(1, "web_search"))
        trail.record(update(2, "terminal"))
        #expect(trail.steps.map(\.step) == [1, 2])
        trail.record(update(2, "", state: .done))
        #expect(trail.steps.count == 2 && trail.latest?.state == .done && trail.latest?.tool == "terminal")
    }

    @Test func newTurnStartsOverAndLongTurnsAreCapped() {
        var trail = TaskTrail()
        for step in 1...(TaskTrail.maxSteps + 5) { trail.record(update(step, "terminal")) }
        #expect(trail.steps.count == TaskTrail.maxSteps && trail.steps.first?.step == 6)
        trail.record(update(1, "read_file", turn: "t2"))
        #expect(trail.turnID == "t2" && trail.steps.count == 1)
        var empty = TaskTrail()
        empty.record(update(3, "", state: .failed))
        #expect(empty.steps.isEmpty)
    }

    @Test func toolsMapToSymbolsAndCommands() {
        #expect(update(1, "terminal").symbol == "terminal" && update(1, "terminal").isCommand)
        #expect(update(1, "web_search").symbol == "magnifyingglass")
        #expect(update(1, "browser_navigate").symbol == "safari")
        #expect(update(1, "write_file").symbol == "doc.text" && !update(1, "write_file").isCommand)
        #expect(update(1, "mystery").symbol == "gearshape.2")
    }
}

struct ChatGroupingTests {
    private func message(_ role: ChatMessage.Role, _ seconds: TimeInterval, text: String = "hi") -> ChatMessage {
        ChatMessage(id: "\(role)\(seconds)", role: role, text: text, date: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
                    status: .received)
    }

    @Test func sameSenderCloseInTimeJoins() {
        #expect(message(.agent, 0).joins(message(.agent, 60)))
        #expect(!message(.agent, 0).joins(message(.agent, 600)))
        #expect(!message(.agent, 0).joins(message(.owner, 10)))
        #expect(!message(.owner, 0).joins(message(.owner, 10, text: "/stop")))
    }
}
