// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

/// H11: the E2E `hello` between app and bridge, and `unsupported` answers.
struct BridgeHelloTests {
    @Test func helloNamesTheAppAndItsCaps() {
        let body = AppHello.body(appVersion: "1.4 (77)")
        #expect(body["type"]?.string == "hello")
        #expect(body["v"]?.int == Int64(AppHello.protocolVersion))
        #expect(body["app"]?.string == "1.4 (77)")
        guard case .array(let caps)? = body["caps"] else { Issue.record("no caps"); return }
        #expect(caps.compactMap(\.string).contains("unsupported"))
    }

    @Test func bridgeHelloIsParsedLeniently() throws {
        let info = try #require(BridgeInfo(hello: ["type": "hello", "v": 1, "bridge": "0.7.0",
                                                   "caps": .array(["call_resume", "BAD NAME", 5, "history"])]))
        #expect(info.bridgeVersion == "0.7.0")
        #expect(info.supports("call_resume") && info.supports("history"))
        #expect(!info.supports("BAD NAME"))
        #expect(info.displayVersion == "0.7.0")
        #expect(BridgeInfo(hello: ["type": "chat"]) == nil)
        let bare = try #require(BridgeInfo(hello: ["type": "hello"]))
        #expect(bare.caps.isEmpty && bare.displayVersion == "Unknown")
    }

    @Test func unknownTypesAreAnsweredButNeverUnsupportedItself() {
        #expect(AppHello.unsupportedReply(to: ["type": "teleport"])?["unknown"]?.string == "teleport")
        #expect(AppHello.unsupportedReply(to: ["type": "unsupported", "unknown": "x"]) == nil)
        #expect(AppHello.unsupportedReply(to: ["type": "hello"]) == nil)
        let odd = AppHello.unsupportedReply(to: ["type": "Weird Type!"])
        #expect(odd?["type"]?.string == "unsupported" && odd?["unknown"] == nil)
        #expect(AppHello.unsupportedReply(to: ["no_type": true]) == nil)
    }
}
