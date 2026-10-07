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
    /// The reply being prepared (`/stop` cancels it).
    private var replying: Task<Void, Never>?

    /// What Hermes' gateway answers a `/stop` (its `gateway.stop.stopped` / `no_active` texts).
    static let stoppedReply = "⚡ Stopped. You can continue this session."
    static let nothingToStopReply = "No active task to stop."

    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        try? await work(DemoLink(profile: profile, owner: self))
    }

    fileprivate func received(_ body: [String: JSON], profile: RelayProfile) {
        guard body["type"]?.string == "chat", let id = body["id"]?.string else { return }
        let link = DemoLink(profile: profile, owner: self)
        let text = body["text"]?.string ?? ""
        let attachments: Int = if case .array(let items)? = body["attachments"] { items.count } else { 0 }
        if attachments == 0, StopCommand.matches(text) { return stop(id, profile: profile, link: link) }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            chat?.handle(["type": "chat_ack", "id": .string(id)], profile: profile, link: link)
        }
        replying?.cancel()
        replying = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            chat?.handle(["type": "typing"], profile: profile, link: link)
            try? await Task.sleep(for: thinking)
            guard !Task.isCancelled else { return }
            let reply = DemoAgent.reply(to: text, attachments: attachments)
            if reply["kind"] == nil, let full = reply["text"]?.string { await stream(full, profile: profile, link: link) }
            guard !Task.isCancelled else { return }
            chat?.handle(reply, profile: profile, link: link)
            replying = nil
        }
    }

    private func stream(_ text: String, profile: RelayProfile, link: DemoLink) async {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let step = max(3, words.count / 16)
        for end in stride(from: step, to: words.count, by: step) {
            guard !Task.isCancelled else { return }
            chat?.handle(["type": "chat_draft", "draft": "demo", "text": .string(words[..<end].joined(separator: " "))],
                         profile: profile, link: link)
            try? await Task.sleep(for: .milliseconds(90))
        }
    }

    /// The demo's `/stop`: the pending reply never comes; answered the way Hermes answers it.
    private func stop(_ id: String, profile: RelayProfile, link: DemoLink) {
        let wasReplying = replying != nil
        replying?.cancel()
        replying = nil
        let text = wasReplying ? Self.stoppedReply : Self.nothingToStopReply
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            chat?.handle(["type": "chat_ack", "id": .string(id)], profile: profile, link: link)
            try? await Task.sleep(for: .milliseconds(250))
            chat?.handle(["type": "chat", "id": .string(E2EChannel.newMessageID()), "role": "agent", "text": .string(text)],
                         profile: profile, link: link)
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
