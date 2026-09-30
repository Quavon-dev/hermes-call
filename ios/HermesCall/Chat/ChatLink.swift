import Foundation
import HermesCallCore
import os

/// What the chat needs from a relay connection: `RelaySession` in the app, a fake in tests.
protocol ChatLink: Sendable {
    func uploadBlob(_ sealed: Data) async throws -> String
    func send(_ body: [String: JSON], mail: Bool) async throws
    func ackMail(_ ids: [String]) async throws
    func downloadBlob(_ blobID: String, maxSize: Int) async throws -> Data
    func deleteBlob(_ blobID: String) async throws
}

extension RelaySession: ChatLink {}

/// Runs work on a connection to a profile's relay that stays open while it runs (also in the background).
@MainActor
protocol ChatLinkProvider: AnyObject {
    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T?
}

/// The app's shared relay connections (`AppModel.borrowSession`).
@MainActor
final class RelayLinkProvider: ChatLinkProvider {
    private weak var app: AppModel?
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "chat")

    init(app: AppModel) {
        self.app = app
    }

    func withLink<T: Sendable>(_ profile: RelayProfile, _ work: @escaping (any ChatLink) async throws -> T) async -> T? {
        guard let app, let session = try? app.borrowSession(for: profile) else { return nil }
        defer { app.releaseSession(session) }
        do {
            try await session.waitUntilConnected(timeout: 15)
            return try await work(session)
        } catch {
            log.error("chat send failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
