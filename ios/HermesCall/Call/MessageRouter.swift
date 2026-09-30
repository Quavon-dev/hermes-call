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
        case .drop: break
        }
    }
}
