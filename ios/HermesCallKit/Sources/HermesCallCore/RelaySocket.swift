import Foundation

/// One WebSocket to the relay with JSON framing and receive timeouts.
final class RelaySocket: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    let trust: RelayTrust

    init(relay: RelayAddress, path: String, trust: RelayTrust) throws {
        guard let url = URL(string: "wss://\(relay.authority)\(path)") else { throw ProtocolError.invalidHost }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        self.trust = trust
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024
        task.resume()
    }

    /// Completes once TLS and the WebSocket upgrade are done (so the observed pin is known).
    func waitConnected(timeout: TimeInterval = 20) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.trust.waitOpen() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProtocolError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ message: JSON) async throws {
        let text = String(decoding: try message.encoded(), as: UTF8.self)
        try await task.send(.string(text))
    }

    /// Next relay message; relay `error` frames become thrown errors.
    func receive(timeout: TimeInterval = 20, throwingRelayErrors: Bool = true) async throws -> JSON {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await self.task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProtocolError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProtocolError.notConnected }
            return first
        }
        guard case .string(let text) = message, text.utf8.count <= 64 * 1024,
              case .object(let body) = try JSON.decode(Data(text.utf8)), body["t"]?.string != nil
        else { throw ProtocolError.unexpected("invalid relay frame") }
        if throwingRelayErrors, body["t"]?.string == "error" { throw ProtocolError.relay(body["code"]?.string ?? "unknown") }
        return .object(body)
    }

    func expect(_ type: String, timeout: TimeInterval = 20) async throws -> JSON {
        let message = try await receive(timeout: timeout)
        guard message["t"]?.string == type else { throw ProtocolError.unexpected(message["t"]?.string ?? "?") }
        return message
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
