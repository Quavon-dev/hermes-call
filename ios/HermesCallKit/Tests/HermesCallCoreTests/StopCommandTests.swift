import Foundation
import Testing
@testable import HermesCallCore

struct StopCommandTests {
    @Test func matchesOnlyTheBareCommand() {
        #expect(StopCommand.matches("/stop"))
        #expect(StopCommand.matches("  /STOP\n"))
        #expect(!StopCommand.matches("stop"))
        #expect(!StopCommand.matches("/stop now"))
        #expect(!StopCommand.matches("please /stop"))
    }

    @Test func stopMessageIsAnOwnerMessageWithTheCommandAsText() {
        let message = StopCommand.message(id: "abc")
        #expect(message.role == .owner && message.kind == StopCommand.kind && message.text == "/stop")
        #expect(message.status == .pending && message.isStopRequest)
        #expect(message.preview == "Stop requested")
        // On the wire it is a plain chat message: every bridge (and Hermes) understands it.
        let body = ChatWire.body(for: message, uploads: [])
        #expect(body["type"]?.string == "chat" && body["text"]?.string == "/stop")
        #expect(body["kind"] == nil)
    }

    @Test func mirroredOrHistoricStopIsMarkedToo() throws {
        let id = Base64URL.encode(Data(repeating: 7, count: 16))
        let owner = try #require(ChatWire.message(from: ["type": "chat", "id": .string(id), "role": "owner", "text": "/stop"]))
        #expect(owner.isStopRequest)
        // The agent writing "/stop" is just text.
        let agent = try #require(ChatWire.message(from: ["type": "chat", "id": .string(id), "role": "agent", "text": "/stop"]))
        #expect(!agent.isStopRequest && agent.kind == "text")
    }

    @Test func stopIsOfferedWhileTheAgentWorks() {
        let running = TaskUpdate(turnID: "t", step: 1, total: nil, tool: "x", label: "x", preview: nil, state: .running, startedAt: 0)
        let done = TaskUpdate(turnID: "t", step: 1, total: nil, tool: "x", label: "x", preview: nil, state: .done, startedAt: 0)
        #expect(StopCommand.agentIsWorking(typing: true, task: nil))
        #expect(StopCommand.agentIsWorking(typing: false, task: running))
        #expect(!StopCommand.agentIsWorking(typing: false, task: done))
        #expect(!StopCommand.agentIsWorking(typing: false, task: nil))
    }
}
