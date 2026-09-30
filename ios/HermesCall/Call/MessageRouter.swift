import Foundation
import HermesCallCore

/// Reads every relay connection the app opens (one consumer per session, for its lifetime) and hands
/// each E2E message to the model that owns it: chat, phone context, tasks or the call.
@MainActor
final class MessageRouter {
    enum Destination: Equatable, Sendable { case chat, phone, task, call, drop }

    var onChat: (([String: JSON], RelaySession) -> Void)?
    var onPhone: (([String: JSON], RelaySession) -> Void)?
    var onTask: (([String: JSON], RelaySession) -> Void)?
    /// Call signaling (`invite`, `answer`, `hangup`, captions, call approvals…).
    var onCall: (([String: JSON], RelaySession) -> Void)?

    private var pumps: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Where a message goes; everything the app does not know is dropped.
    nonisolated static func destination(for message: [String: JSON]) -> Destination {
        if ChatModel.handles(message) { return .chat }
        if PhoneContextModel.handles(message) { return .phone }
        if TaskActivityModel.handles(message) { return .task }
        return message["call_id"]?.string == nil ? .drop : .call
    }

    /// The `unsupported` answer for a message nobody in the app handles (nil: it has an owner, or is never answered).
    nonisolated static func unsupportedReply(for message: [String: JSON]) -> [String: JSON]? {
        destination(for: message) == .drop ? AppHello.unsupportedReply(to: message) : nil
    }

    /// Starts reading `session` unless it is read already; the stream ends when the session is stopped.
    func listen(to session: RelaySession) {
        let key = ObjectIdentifier(session)
        guard pumps[key] == nil else { return }
        pumps[key] = Task { [weak self] in
            for await message in session.messages {
                self?.route(message, from: session)
            }
            self?.pumps[key] = nil
        }
    }

    func route(_ message: [String: JSON], from session: RelaySession) {
        switch Self.destination(for: message) {
        case .chat: onChat?(message, session)
        case .phone: onPhone?(message, session)
        case .task: onTask?(message, session)
        case .call: onCall?(message, session)
        case .drop: answerUnknown(message, from: session)
        }
    }

    /// A newer bridge sent something this app does not know: say so (so it can fall back), and take an
    /// unknown mailbox message out of the mailbox instead of fetching it again forever.
    private func answerUnknown(_ message: [String: JSON], from session: RelaySession) {
        let reply = Self.unsupportedReply(for: message)
        let mailID = message["mail_id"]?.string
        guard reply != nil || mailID != nil else { return }
        Task {
            if let reply { try? await session.send(reply) }
            if let mailID { try? await session.ackMail([mailID]) }
        }
    }
}
