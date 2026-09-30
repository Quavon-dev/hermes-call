import Foundation

/// Authenticated connection of this device to its relay, carrying E2E messages to/from the bridge.
public actor RelaySession {
    public enum Status: Sendable, Equatable { case disconnected, connecting, connected }

    public nonisolated let profile: RelayProfile
    public nonisolated let messages: AsyncStream<[String: JSON]>
    private let messageSink: AsyncStream<[String: JSON]>.Continuation
    private let onStatus: @Sendable (Status) -> Void
    private let onReady: @Sendable (RelayInfo) -> Void
    /// What the relay said about itself on the last connect (version, caps); nil before the first one.
    public private(set) var relayInfo: RelayInfo?
    /// The E2E `hello` sent to the bridge after every connect (nil: none, e.g. in the extensions).
    private let hello: [String: JSON]?
    private let onBridgeHello: @Sendable (BridgeInfo) -> Void
    /// What the bridge said in its `hello` (nil: not yet, or an older bridge that sends none).
    public private(set) var bridgeInfo: BridgeInfo?
    private let channel: E2EChannel
    private let bridgeKey: Data
    private var socket: RelaySocket?
    private var pending: [Int64: CheckedContinuation<JSON, Error>] = [:]
    private var nextRID: Int64 = 1
    private var loop: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var stopped = false
    /// The pause before the next connection attempt; `reconnectNow` cuts it short.
    private var backoffSleep: Task<Void, Never>?
    private var skipBackoff = false
    /// Mail delivered to `messages` but not acked yet: relay mail id → (message id, timestamp).
    private var unackedMail: [String: (mid: String, ts: Int64)] = [:]

    /// Mailbox messages arrive in `messages` with an added local key `mail_id`; ack them with
    /// `ackMail` once stored. Without `acceptsMail` (extensions) they are left for the app.
    private let acceptsMail: Bool

    public init(profile: RelayProfile, replayStore: UserDefaults? = nil, mailStore: UserDefaults? = SharedContainer.defaults,
                acceptsMail: Bool = true, onStatus: @escaping @Sendable (Status) -> Void = { _ in },
                onReady: @escaping @Sendable (RelayInfo) -> Void = { _ in }, hello: [String: JSON]? = nil,
                onBridgeHello: @escaping @Sendable (BridgeInfo) -> Void = { _ in }) throws {
        self.profile = profile
        self.onStatus = onStatus
        self.onReady = onReady
        self.hello = hello
        self.onBridgeHello = onBridgeHello
        self.acceptsMail = acceptsMail
        channel = try profile.channel(seenStore: replayStore, mailStore: mailStore)
        bridgeKey = try Base64URL.decode(profile.bridgeBoxKey, length: 32)
        (messages, messageSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func start() {
        guard loop == nil, !stopped else { return }
        loop = Task { await self.run() }
    }

    /// Final: a stopped session never reconnects and its `messages` stream ends.
    public func stop() {
        stopped = true
        backoffSleep?.cancel()
        loop?.cancel()
        loop = nil
        socket?.close()
        socket = nil
        failPending(ProtocolError.notConnected)
        let blocked = waiters
        waiters.removeAll()
        blocked.values.forEach { $0.resume() }
        messageSink.finish()
        onStatus(.disconnected)
    }

    public var isConnected: Bool { socket != nil }

    /// The network came back (or the app returned): try again at once instead of after the backoff.
    public func reconnectNow() {
        guard !stopped, socket == nil else { return }
        skipBackoff = true
        backoffSleep?.cancel()
        start()
    }

    /// Round trip to the relay (WebSocket ping), for diagnostics; nil when not connected or no answer in time.
    public func pingRelay(timeout: TimeInterval = 5) async -> Duration? {
        guard let socket else { return nil }
        return try? await socket.ping(timeout: timeout)
    }

    public func waitUntilConnected(timeout: TimeInterval = 15) async throws {
        start()
        if socket != nil { return }
        guard !stopped else { throw ProtocolError.notConnected }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.connectedSignal()
                guard await self.isConnected else { throw ProtocolError.notConnected }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ProtocolError.notConnected
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Returns when connected, or as soon as the waiting task is cancelled.
    private func connectedSignal() async {
        if socket != nil || stopped { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.releaseWaiter(id) }
        }
    }

    private func releaseWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Relay request/response (`turn`, `register_push`, …). `requires`: a relay cap without which the request is
    /// not sent (relays up to 0.6.2 drop the connection on unknown types); it then fails with `.relay("unsupported")`,
    /// like the answer of a newer relay that does not know the type.
    public func request(_ message: [String: JSON], requires cap: String? = nil, timeout: TimeInterval = 15) async throws -> JSON {
        try await waitUntilConnected(timeout: timeout)
        guard let socket else { throw ProtocolError.notConnected }
        if let missing = (relayInfo ?? RelayInfo(ready: [:])).check(requires: cap) { throw missing }
        let rid = nextRID
        nextRID += 1
        var body = message
        body["rid"] = .int(rid)
        return try await withCheckedThrowingContinuation { continuation in
            pending[rid] = continuation
            Task {
                do { try await socket.send(.object(body)) } catch { self.resolve(rid, .failure(error)) }
                try? await Task.sleep(for: .seconds(timeout))
                self.resolve(rid, .failure(ProtocolError.timeout))
            }
        }
    }

    /// Seal and send an E2E message to the bridge. `mail`: a chat message with its own id, accepted by
    /// the bridge even if it arrives late (retries), see `E2EChannel`.
    public func send(_ body: [String: JSON], mail: Bool = false) async throws {
        try await waitUntilConnected()
        guard let socket else { throw ProtocolError.notConnected }
        let mid = mail ? E2EChannel.newMessageID() : nil
        let sealed = try channel.seal(to: profile.bridgeID, peerKey: bridgeKey, body: body, mid: mid)
        try await socket.send(["t": "e2e", "data": .string(sealed)])
    }

    /// Asks the relay for stored mailbox messages; they arrive in `messages`.
    public func fetchMail() async throws {
        for _ in 0..<10 {
            let reply = try await request(["t": "mail_fetch"])
            guard reply["more"]?.bool == true else { return }
        }
    }

    /// Call once the messages are stored: marks them seen (replay protection) and deletes them at the relay.
    public func ackMail(_ ids: [String]) async throws {
        for id in ids {
            if let seen = unackedMail.removeValue(forKey: id) { channel.markMailSeen(mid: seen.mid, ts: seen.ts) }
        }
        for batch in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            _ = try await request(["t": "mail_ack", "ids": .array(batch.map { .string($0) })])
        }
    }

    // MARK: encrypted attachments

    /// Stores sealed bytes (see `Blob`) for the bridge; returns the blob id.
    public func uploadBlob(_ sealed: Data) async throws -> String {
        let ticket = try await request(["t": "blob_put", "size": .int(Int64(sealed.count))])
        guard let blobID = ticket["blob_id"]?.string, let token = ticket["token"]?.string else {
            throw ProtocolError.unexpected("blob ticket")
        }
        var request = try blobRequest(blobID, token: token)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let session = blobSession()
        defer { session.finishTasksAndInvalidate() }
        // A busy relay (503) keeps the ticket: the same PUT again after a pause.
        _ = try await BlobRetry.run(maxAttempts: BlobRetry.maxUploadAttempts) { [request] in
            let (_, response) = try await session.upload(for: request, from: sealed)
            return (Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return blobID
    }

    /// A download ticket works three times; a relay still busy (503) after that gets one more ticket.
    public func downloadBlob(_ blobID: String, maxSize: Int = Blob.maxSealedSize) async throws -> Data {
        let session = blobSession()
        defer { session.finishTasksAndInvalidate() }
        for ticketNumber in 1...BlobRetry.maxDownloadTickets {
            let ticket = try await request(["t": "blob_get", "blob_id": .string(blobID)])
            guard let token = ticket["token"]?.string else { throw ProtocolError.unexpected("blob ticket") }
            let request = try blobRequest(blobID, token: token)
            do {
                let data = try await BlobRetry.run(maxAttempts: BlobRetry.downloadUsesPerTicket) {
                    let (data, response) = try await session.data(for: request)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard data.count <= maxSize else { throw ProtocolError.unexpected("blob download") }
                return data
            } catch ProtocolError.relay("busy") where ticketNumber < BlobRetry.maxDownloadTickets {
                try await Task.sleep(for: BlobRetry.pause(before: BlobRetry.downloadUsesPerTicket + 1))
            }
        }
        throw ProtocolError.relay("busy")
    }

    public func deleteBlob(_ blobID: String) async throws {
        _ = try await request(["t": "blob_delete", "blob_id": .string(blobID)])
    }

    private func blobRequest(_ blobID: String, token: String) throws -> URLRequest {
        guard (try? Base64URL.decode(blobID, length: 16)) != nil,
              let url = URL(string: "https://\(profile.relay.authority)/v1/blobs/\(blobID)") else { throw ProtocolError.invalidField }
        var request = URLRequest(url: url, timeoutInterval: BlobRetry.deadline)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func blobSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = BlobRetry.deadline
        let trust = RelayTrust(profile.pin.isEmpty ? .webPKI : .pinned(profile.pin))
        return URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    private func receiveMail(id: String, data: String) {
        guard var body = try? channel.peekMail(from: profile.bridgeID, peerKey: bridgeKey, data: data),
              let mid = body["mid"]?.string, let ts = body["ts"]?.int else {
            // Undecryptable or already processed: nothing to keep, drop it from the mailbox.
            Task { try? await ackMail([id]) }
            return
        }
        unackedMail[id] = (mid, ts)
        body["mail_id"] = .string(id)
        messageSink.yield(body)
    }

    private func resolve(_ rid: Int64, _ result: Result<JSON, Error>) {
        guard let continuation = pending.removeValue(forKey: rid) else { return }
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            onStatus(.connecting)
            var closeCode: Int?
            do {
                let socket = try await authenticate()
                guard !stopped else { return socket.close() }
                self.socket = socket
                backoff = 1
                onStatus(.connected)
                let ready = waiters
                waiters.removeAll()
                ready.values.forEach { $0.resume() }
                if let hello { Task { try? await self.send(hello) } }
                try await readLoop(socket)
            } catch {
                closeCode = self.socket?.closeCode
                failPending(error)
            }
            socket?.close()
            socket = nil
            onStatus(.disconnected)
            guard !Task.isCancelled else { return }
            if skipBackoff {
                skipBackoff = false
                backoff = 1
                continue
            }
            let step = RelayBackoff.after(closeCode: closeCode, backoff: backoff)
            let pause = step.pause
            let sleep = Task { _ = try? await Task.sleep(for: .seconds(pause)) }
            backoffSleep = sleep
            await sleep.value
            backoffSleep = nil
            if skipBackoff {
                skipBackoff = false
                backoff = 1
            } else {
                backoff = step.next
            }
        }
    }

    private func authenticate() async throws -> RelaySocket {
        let trust = RelayTrust(profile.pin.isEmpty ? .webPKI : .pinned(profile.pin))
        let socket = try RelaySocket(relay: profile.relay, path: "/v1/ws", trust: trust)
        do {
            let challenge = try await socket.expect("challenge")
            let nonce = try Base64URL.decode(challenge["nonce"]?.string ?? "", length: 32)
            let message = RelayAuth.message(authority: profile.relay.authority, role: "device",
                                            identity: profile.deviceID, nonce: nonce)
            let signature = try Sodium.sign(message, secretKey: try Base64URL.decode(profile.keys.signSecret, length: 64))
            try await socket.send(.object(RelayAuth.body(role: "device", identity: profile.deviceID,
                                                         signature: Base64URL.encode(signature))))
            let info = RelayInfo(ready: try await socket.expect("ready"))
            relayInfo = info
            onReady(info)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    private func readLoop(_ socket: RelaySocket) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive(timeout: 3600, throwingRelayErrors: false)
            if let rid = message["rid"]?.int {
                // `unsupported` included: the relay did not know the request and stays connected.
                resolve(rid, RelayReply.error(in: message).map { .failure($0) } ?? .success(message))
            } else if message["t"]?.string == "e2e", let data = message["data"]?.string,
                      let body = try? channel.open(from: profile.bridgeID, peerKey: bridgeKey, data: data) {
                if let info = BridgeInfo(hello: body) {
                    bridgeInfo = info
                    onBridgeHello(info)
                } else {
                    messageSink.yield(body)
                }
            } else if message["t"]?.string == "mail", acceptsMail, let id = message["id"]?.string,
                      let data = message["data"]?.string {
                receiveMail(id: id, data: data)
            }
        }
    }
}
