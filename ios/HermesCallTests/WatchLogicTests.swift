import Foundation
import HermesCallCore
import Testing
@testable import HermesCall

/// The watch ⇄ iPhone rules (WatchShared, compiled into both apps) and the snapshot the iPhone sends.
struct WatchLogicTests {
    @Test func requestsSurviveTheTripAndJunkIsRefused() {
        for kind: WatchRequest.Kind in [.call, .message("Buy milk"), .deny(approvalID: "r1"), .voice(duration: 4.5)] {
            let request = WatchRequest(kind: kind)
            #expect(WatchRequest(request.dictionary) == request)
        }
        #expect(WatchRequest([WatchLink.action: WatchLink.callAction]) == nil)
        #expect(WatchRequest([WatchLink.requestID: "x", WatchLink.action: "format_disk"]) == nil)
        #expect(WatchRequest([WatchLink.requestID: "x", WatchLink.action: WatchLink.messageAction, WatchLink.text: "   "]) == nil)
        #expect(WatchRequest([WatchLink.requestID: "x", WatchLink.action: WatchLink.messageAction,
                              WatchLink.text: String(repeating: "a", count: WatchLink.maxText + 1)]) == nil)
        #expect(WatchRequest([WatchLink.requestID: "x", WatchLink.action: WatchLink.voiceAction, WatchLink.duration: 0.1]) == nil)
    }

    @Test func messagesWaitForAnUnreachablePhoneButCallsDoNot() {
        let message = WatchRequest(kind: .message("hi")), call = WatchRequest(kind: .call)
        #expect(message.route(activated: true, reachable: true) == .live)
        #expect(message.route(activated: true, reachable: false) == .queued)
        #expect(WatchRequest(kind: .deny(approvalID: "r")).route(activated: true, reachable: false) == .queued)
        #expect(call.route(activated: true, reachable: false) == .unavailable)
        #expect(message.route(activated: false, reachable: true) == .unavailable)
    }

    @Test func aRequestIsDoneOnce() {
        var handled = HandledRequests()
        let first = handled.insert("a"), again = handled.insert("a")
        #expect(first && !again)
        for index in 0..<HandledRequests.limit { _ = handled.insert("n\(index)") }
        #expect(handled.ids.count == HandledRequests.limit)
        // Long forgotten: done again (the queue never holds requests that old).
        let forgotten = handled.insert("a")
        #expect(forgotten)
    }

    @Test func wristTapsFollowTheCall() {
        #expect(WatchCallCue.between(nil, .ringing) == .ringing)
        #expect(WatchCallCue.between(.ringing, .connecting) == nil)
        #expect(WatchCallCue.between(.connecting, .connected) == .started)
        #expect(WatchCallCue.between(.connected, nil) == .ended)
        #expect(WatchCallCue.between(nil, nil) == nil)
    }

    @MainActor @Test func snapshotHidesTextAndSystemEntriesAndCarriesTheApproval() throws {
        let now = Date()
        let messages = (0..<20).map { ChatMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? .agent : .owner, text: "**secret** \($0)",
                                                  date: now, status: .received) }
            + [ChatMessage.callEntry(CallSummary(direction: .incoming, duration: 3), id: "c")]
        let approval = ChatApproval(id: "r", profileID: UUID(), command: String(repeating: "x", count: 500), details: "", mailID: nil)
        let hidden = WatchBridge.snapshot(agentName: "Atlas", palette: "ice", paired: true, messages: messages, showText: false,
                                          approval: approval, phase: .connected(since: now))
        #expect(hidden.messages.count == WatchSnapshot.maxMessages && hidden.messages.allSatisfy { $0.text == "New message" })
        #expect(hidden.messages.last?.id == "m19" && hidden.call == .connected)
        #expect(hidden.approval?.id == "r" && hidden.approval?.command.count == WatchSnapshot.maxCommand)
        let shown = WatchBridge.snapshot(agentName: "Atlas", palette: "ice", paired: true, messages: messages, showText: true,
                                         approval: nil, phase: .idle)
        #expect(shown.messages.last?.text == "secret 19" && shown.call == nil && shown.approval == nil)
        // Older watch apps read snapshots without the new fields, and new ones read old snapshots.
        let old = try JSONEncoder().encode(WatchSnapshot(agentName: "A", palette: "gold", paired: true, messages: []))
        #expect(try JSONDecoder().decode(WatchSnapshot.self, from: old).approval == nil)
    }
}
