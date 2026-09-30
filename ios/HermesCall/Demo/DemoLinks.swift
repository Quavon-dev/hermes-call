import Foundation
import HermesCallCore

/// The chat's connections: the relay for real agents, a local stand-in for the demo agent.
@MainActor
final class AgentLinks: ChatLinkProvider {
    private let relay: RelayLinkProvider
    let demo = DemoLinkProvider()

    init(app: AppModel) {
        relay = RelayLinkProvider(app: app)
    }

    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        profile.isDemo ? await demo.withLink(profile, work) : await relay.withLink(profile, work)
    }
}

/// Answers the demo agent's chat on this iPhone, the way a bridge would: confirms each message, shows
/// "typing", then replies (DemoAgent). Nothing is uploaded or sent anywhere.
@MainActor
final class DemoLinkProvider: ChatLinkProvider {
    weak var chat: ChatModel?
    /// Seconds between the owner's message and the reply (0 in tests).
    var thinking: Duration = .milliseconds(1100)

    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        try? await work(DemoLink(profile: profile, owner: self))
    }

    fileprivate func received(_ body: [String: JSON], profile: RelayProfile) {
        guard body["type"]?.string == "chat", let id = body["id"]?.string else { return }
        let link = DemoLink(profile: profile, owner: self)
        let text = body["text"]?.string ?? ""
        let attachments: Int = if case .array(let items)? = body["attachments"] { items.count } else { 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            chat?.handle(["type": "chat_ack", "id": .string(id)], profile: profile, link: link)
            try? await Task.sleep(for: .milliseconds(250))
            chat?.handle(["type": "typing"], profile: profile, link: link)
            try? await Task.sleep(for: thinking)
            chat?.handle(DemoAgent.reply(to: text, attachments: attachments), profile: profile, link: link)
        }
    }
}

/// A "connection" that never leaves the phone.
struct DemoLink: ChatLink {
    let profile: RelayProfile
    let owner: DemoLinkProvider

    func uploadBlob(_ sealed: Data) async throws -> String { Base64URL.encode(Sodium.randomBytes(16)) }
    func send(_ body: [String: JSON], mail: Bool) async throws { await owner.received(body, profile: profile) }
    func ackMail(_ ids: [String]) async throws {}
    func downloadBlob(_ blobID: String, maxSize: Int) async throws -> Data { throw ProtocolError.notConnected }
    func deleteBlob(_ blobID: String) async throws {}
}

extension RelayProfile {
    /// The offline demo agent (never stored in the Keychain, never connected).
    var isDemo: Bool { id == DemoAgent.id }
}
