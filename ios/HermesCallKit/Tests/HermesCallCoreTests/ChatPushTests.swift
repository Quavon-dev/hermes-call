import Foundation
import Testing
@testable import HermesCallCore

/// The notification extension's decisions: which profile a push belongs to and what it may show.
struct ChatPushTests {
    let bridgeKeys = try? Sodium.boxKeypair()

    func profile(name: String) throws -> RelayProfile {
        let bridge = try #require(bridgeKeys)
        return RelayProfile(id: UUID(), label: name, relay: RelayAddress(host: "relay.invalid", port: 443), pin: "", deviceID: "D-\(name)",
                            bridgeID: "B", bridgeName: name, bridgeBoxKey: Base64URL.encode(bridge.publicKey),
                            bridgeSignKey: Base64URL.encode(Sodium.randomBytes(32)), keys: try DeviceKeys.generate(), created: Date(),
                            palette: .ice)
    }

    func seal(_ body: [String: JSON], to profile: RelayProfile) throws -> String {
        let bridge = try #require(bridgeKeys)
        return try E2EChannel(myID: "B", secretKey: bridge.secretKey)
            .seal(to: profile.deviceID, peerKey: try Base64URL.decode(profile.keys.boxPublic, length: 32), body: body,
                  mid: E2EChannel.newMessageID())
    }

    func present(_ sealed: String, _ profiles: [RelayProfile], showText: Bool = true, permission: PhonePermission = .ask)
        -> PushPresentation? {
        ChatPush.presentation(sealed: sealed, profiles: profiles, mailStore: UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)"),
                              showText: showText, permission: { _ in permission })
    }

    @Test func findsTheRightAgentAndShowsTheText() throws {
        let home = try profile(name: "Atlas"), office = try profile(name: "Nova")
        let body: [String: JSON] = ["type": "chat", "id": .string(E2EChannel.newMessageID()), "role": "agent", "text": "**Backup** done"]
        let shown = try #require(present(try seal(body, to: office), [home, office]))
        #expect(shown.profileID == office.id && shown.title == "Nova" && shown.body == "Backup done" && shown.category == .chat)
        #expect(shown.message?.role == .agent && shown.palette == .ice && shown.userInfo == ["profile": office.id.uuidString])
        #expect(present(try seal(body, to: office), [home], showText: true) == nil)
        #expect(present(try seal(body, to: office), [office], showText: false)?.body == "New message")
    }

    @Test func approvalsAndPhoneQueries() throws {
        let agent = try profile(name: "Atlas")
        let approval = present(try seal(["type": "approval_request", "request_id": "r", "command": "rm -rf /", "description": "x",
                                         "chat": true], to: agent), [agent])
        #expect(approval?.category == .approval && approval?.timeSensitive == true && approval?.body.contains("rm") == false)
        let query: [String: JSON] = ["type": "phone_query", "query_id": .string(Base64URL.encode(Data(repeating: 7, count: 16))),
                                     "capability": "location", "reason": "Find a pharmacy",
                                     "expires": .int(Int64((Date().timeIntervalSince1970 + 60) * 1000)), "params": .object([:])]
        let ask = try #require(present(try seal(query, to: agent), [agent]))
        #expect(ask.category == .phone && ask.queryID != nil && ask.userInfo["query"] == ask.queryID)
        #expect(present(try seal(query, to: agent), [agent], permission: .no)?.category == .phoneInfo)
    }

    @Test func junkShowsNothing() throws {
        let agent = try profile(name: "Atlas")
        #expect(present("not a push", [agent]) == nil)
        #expect(present(try seal(["type": "typing"], to: agent), [agent]) == nil)
    }
}
