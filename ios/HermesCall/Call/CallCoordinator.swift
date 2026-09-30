import AVFoundation
@preconcurrency import CallKit
import Foundation
import HermesCallCore
import LocalAuthentication
import os
@preconcurrency import WebRTC

/// Drives calls through CallKit (so they behave like real phone calls) and WebRTC.
@MainActor @Observable
final class CallCoordinator: NSObject {
    enum Phase: Equatable {
        case idle
        case ringing
        case connecting
        case connected(since: Date)
        case ended(reason: String)
    }

    struct Caption: Identifiable, Equatable {
        let id = UUID()
        let fromAgent: Bool
        let text: String
        let date: Date
    }

    static let maxCaptions = 4

    struct Approval: Identifiable, Equatable {
        let id: String
        let callID: String
        let command: String
        let details: String
    }

    private(set) var phase: Phase = .idle
    private(set) var isMuted = false
    private(set) var isSpeaker = false
    private(set) var isTalking = false
    private(set) var peerName = RelayProfile.defaultAgentName
    /// The relay profile of the current (or last) call, once known.
    private(set) var profileID: UUID?
    private(set) var relayLabel = "relay"
    private(set) var callReason = ""
    var pendingApproval: Approval?
    /// The latest spoken lines of this call (bridge `caption`), newest last.
    private(set) var captions: [Caption] = []
    private var approvalInProgress = false
    /// Talk mode for the next outgoing call (hold-to-talk on the presence), else the preference.
    private var nextTalkMode: TalkMode?
    /// Same limit as the bridge: longer commands are denied there, never shown cut off.
    static let maxApprovalText = 4000

    private let app: AppModel
    private let provider: CXProvider
    private let controller = CXCallController()
    private let ringback = RingbackTone()
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "call")
    private var call: ActiveCall?
    private var pumps: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Rings that already ended, so a late `invite` (e.g. the reply to `invite_query`) cannot ring again.
    private var finishedCallIDs: [String] = []
    /// Chat messages share the relay connections; the chat model takes them from here.
    var onChatMessage: (([String: JSON], RelaySession) -> Void)?
    /// Phone context queries from the agent (PhoneContextModel).
    var onPhoneMessage: (([String: JSON], RelaySession) -> Void)?
    /// The agent's task progress (TaskActivityModel).
    var onTaskMessage: (([String: JSON], RelaySession) -> Void)?
    /// A connected call ended: (relay profile, duration, incoming), for the chat's call entries.
    var onCallEnded: ((UUID, TimeInterval, Bool) -> Void)?

    private struct ActiveCall {
        let uuid: UUID
        let callID: String
        let incoming: Bool
        let talkMode: TalkMode
        /// For an incoming ring: nil until one bridge confirms the call id with `invite`.
        var session: RelaySession?
        /// Incoming ring: relays asked with `invite_query` (the push does not say which bridge rang).
        var candidates: [RelaySession] = []
        var accepted = false
        var confirmTimeout: Task<Void, Never>?
        var rtc: WebRTCCall?
        var transcriber: PhoneTranscriber?
        var answer: CheckedContinuation<String, Error>?
    }

    static let answerTimeout: Duration = .seconds(20)
    static let inviteTimeout: Duration = .seconds(15)

    init(app: AppModel) {
        self.app = app
        provider = CXProvider(configuration: Self.configuration(includeInRecents: app.preferences.includeInRecents))
        super.init()
        provider.setDelegate(self, queue: .main)
        app.onSessionCreated = { [weak self] session in self?.listen(to: session) }
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    static func configuration(includeInRecents: Bool) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = includeInRecents
        return configuration
    }

    func applyRecentsPreference() {
        provider.configuration = Self.configuration(includeInRecents: app.preferences.includeInRecents)
    }

    var inCall: Bool { call != nil }

    func telemetry() async -> CallTelemetry {
        await call?.rtc?.telemetry() ?? CallTelemetry()
    }
    var isConnected: Bool { if case .connected = phase { true } else { false } }

    /// Live voice bands of the current call (agent, owner), when its audio runs through our engine.
    /// Reading consumes the analyzers' new samples: call it from one place only (the presence, once per frame).
    func spectrum() -> (agent: [Float], mic: [Float])? {
        guard call?.rtc?.usesEngineAudio == true else { return nil }
        let device = EngineAudioDevice.shared
        return (device.agentSpectrum.bands(), device.micSpectrum.bands())
    }

    /// The agent's played loudness as of the last `spectrum()` read (no new analysis).
    var agentPlayoutLevel: Float? {
        call?.rtc?.usesEngineAudio == true ? EngineAudioDevice.shared.agentSpectrum.currentLevel : nil
    }

    // MARK: user actions

    func startCall(talkMode: TalkMode? = nil) async {
        guard call == nil, let profile = app.activeProfile else { return }
        nextTalkMode = talkMode
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .ended(reason: "Microphone access is off. Allow it in Settings › Hermes Call.")
            return
        }
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: profile.bridgeName))
        action.isVideo = false
        do {
            try await controller.request(CXTransaction(action: action))
        } catch {
            phase = .ended(reason: "Could not start the call (\(error.localizedDescription)).")
        }
    }

    /// If CallKit rejects the transaction (e.g. it lost track of the call), hang up anyway.
    func hangUp() {
        guard let call else { return }
        let uuid = call.uuid
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.end(uuid: uuid, reason: "Call ended.", notify: true) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let call else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.uuid, muted: muted))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.applyMute(muted) }
        }
    }

    private func applyMute(_ muted: Bool) {
        isMuted = muted
        if let current = call { updateMic(current) }
    }

    /// The microphone (and on-device transcription) is open only when not muted and, in
    /// push-to-talk, while the button is held.
    private func updateMic(_ current: ActiveCall) {
        let open = !isMuted && (current.talkMode == .handsFree || isTalking)
        current.rtc?.micEnabled = open
        current.transcriber?.setGated(!open)
    }

    func toggleSpeaker() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.overrideOutputAudioPort(isSpeaker ? .none : .speaker)
            isSpeaker.toggle()
        } catch {
            log.error("speaker switch failed")
        }
    }

    /// The talk mode of the current call.
    var talkMode: TalkMode? { call?.talkMode }

    /// Cut the agent off (tap on the presence): the bridge stops speaking and listens.
    func interrupt() {
        guard let current = call, isConnected else { return }
        Task { try? await current.session?.send(["type": "interrupt", "call_id": .string(current.callID)]) }
    }

    /// Same limits as the bridge: one picture per second, 30 per call.
    static let maxImagesPerCall = 30
    private var imagesSent: (callID: String, count: Int, last: Date)?

    /// "Look at this": sends a still (JPEG) to the agent of the connected call as an encrypted blob.
    /// The bridge attaches it to the next turn of the conversation.
    func showImage(_ jpeg: Data) async -> Bool {
        guard let current = call, isConnected, let session = current.session else { return false }
        let before = imagesSent
        var sent = imagesSent?.callID == current.callID ? imagesSent! : (current.callID, 0, .distantPast)
        guard sent.count < Self.maxImagesPerCall, Date().timeIntervalSince(sent.last) >= 1 else { return false }
        sent.count += 1
        sent.last = Date()
        imagesSent = sent
        var delivered = false
        // A failed upload gives the picture back (quota and the one-second window).
        defer { if !delivered, imagesSent?.callID == current.callID { imagesSent = before } }
        do {
            let (key, sealed) = try Blob.seal(jpeg)
            let blobID = try await session.uploadBlob(sealed)
            try await session.send(["type": "call_image", "call_id": .string(current.callID), "blob_id": .string(blobID),
                                    "key": .string(Base64URL.encode(key)), "mime": "image/jpeg"])
            delivered = true
            return true
        } catch {
            log.error("picture not sent: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    var imagesLeft: Int {
        guard let current = call else { return 0 }
        return Self.maxImagesPerCall - (imagesSent?.callID == current.callID ? imagesSent!.count : 0)
    }

    /// Push-to-talk: the microphone is live only while the button is held.
    func setTalking(_ down: Bool) {
        guard let current = call, current.talkMode == .pushToTalk, down != isTalking else { return }
        isTalking = down
        updateMic(current)
        Task { try? await current.session?.send(["type": "ptt", "call_id": .string(current.callID), "down": .bool(down)]) }
    }

    /// Approving needs Face ID / passcode; denying never does.
    func answerApproval(approve: Bool) async {
        guard let approval = pendingApproval, !approvalInProgress, let current = call, approval.callID == current.callID
        else { return }
        approvalInProgress = true
        defer { approvalInProgress = false }
        var choice = "deny"
        if approve {
            let context = LAContext()
            let reason = "Approve the command your assistant wants to run."
            if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
                choice = "once"
            }
        }
        guard pendingApproval?.id == approval.id, call?.callID == approval.callID else { return }
        pendingApproval = nil
        try? await current.session?.send([
            "type": "approval", "call_id": .string(approval.callID), "request_id": .string(approval.id), "choice": .string(choice),
        ])
    }

    // MARK: call flow

    private func startOutgoing(uuid: UUID) {
        guard let profile = app.activeProfile, let session = try? app.borrowSession(for: profile) else {
            phase = .ended(reason: "No relay selected.")
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            return
        }
        call = ActiveCall(uuid: uuid, callID: Base64URL.encode(Sodium.randomBytes(16)), incoming: false,
                          talkMode: nextTalkMode ?? app.preferences.talkMode, session: session)
        nextTalkMode = nil
        show(profile)
        callReason = ""
        phase = .connecting
        listen(to: session)
        Task { await negotiate(uuid: uuid) }
    }

    /// The phone always sends the offer: for its own calls with a new call id, for a ring with the ring's.
    private func negotiate(uuid: UUID) async {
        guard let current = call, current.uuid == uuid, let session = current.session else { return }
        do {
            try await session.waitUntilConnected(timeout: 15)
            let turn = try await session.request(["t": "turn"])
            let transcriber = await startPhoneTranscriber(callID: current.callID, session: session)
            let rtc = try WebRTCCall(turn: turn, relayHost: session.profile.relay.host, onDeviceSpeech: transcriber != nil)
            EngineAudioDevice.shared.agentSpectrum.reset()
            EngineAudioDevice.shared.micSpectrum.reset()
            guard call?.uuid == uuid else {
                await transcriber?.stop()
                return rtc.close()
            }
            rtc.onStateChange = { [weak self] state in self?.mediaChanged(state, uuid: uuid) }
            call?.rtc = rtc
            call?.transcriber = transcriber
            if let updated = call { updateMic(updated) }
            let started = Date()
            let offer = try await rtc.makeOffer()
            log.info("offer ready after \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
            guard call?.uuid == uuid else { return rtc.close() }
            var offerMessage: [String: JSON] = ["type": "offer", "call_id": .string(current.callID), "sdp": .string(offer)]
            if transcriber != nil { offerMessage["stt"] = "device" }
            try await session.send(offerMessage)
            let answer = try await waitForAnswer()
            log.info("answer received")
            try await rtc.accept(answer: answer)
            log.info("call negotiated")
        } catch {
            log.error("call setup failed: \(String(describing: error), privacy: .public)")
            end(uuid: uuid, reason: Self.describe(error), notify: true)
        }
    }

    // MARK: incoming calls (VoIP push)

    /// iOS requires every VoIP push to be reported to CallKit at once, so this happens before we know
    /// whether the ring is real; invalid or unconfirmed rings are ended immediately.
    func reportIncomingPush(callID: String?, completion: @escaping @Sendable () -> Void) {
        let uuid = callID.flatMap(Self.callUUID) ?? UUID()
        let profiles = app.profiles
        let name = profiles.count == 1 ? profiles[0].bridgeName : "Hermes"
        let accepted = callID.map { !finishedCallIDs.contains($0) } == true && call == nil && !profiles.isEmpty
        if accepted, let callID {
            call = ActiveCall(uuid: uuid, callID: callID, incoming: true, talkMode: app.preferences.talkMode)
            peerName = name
            relayLabel = profiles.count == 1 ? profiles[0].label : "relay"
            profileID = profiles.count == 1 ? profiles[0].id : nil
            callReason = ""
            phase = .ringing
        }
        provider.reportNewIncomingCall(with: uuid, update: Self.update(caller: name)) { [weak self] error in
            completion()
            Task { @MainActor in self?.incomingReported(uuid: uuid, accepted: accepted, error: error) }
        }
    }

    /// The call id is 16 random bytes, so it doubles as the CallKit UUID: a push and an `invite`
    /// for the same ring become one call (CallKit rejects the second report as a duplicate).
    static func callUUID(_ callID: String) -> UUID? {
        guard let bytes = try? Base64URL.decode(callID, length: 16) else { return nil }
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// While the app is open, the bridge's E2E `invite` rings directly (no push needed).
    private func ringFromInvite(callID: String, session incoming: RelaySession, reason: String) {
        guard let uuid = Self.callUUID(callID), !finishedCallIDs.contains(callID),
              let session = try? app.borrowSession(for: incoming.profile) else { return }
        guard session === incoming else { return app.releaseSession(session) }
        call = ActiveCall(uuid: uuid, callID: callID, incoming: true, talkMode: app.preferences.talkMode, session: session)
        show(session.profile)
        callReason = String(reason.prefix(200))
        phase = .ringing
        provider.reportNewIncomingCall(with: uuid, update: Self.update(caller: session.profile.bridgeName)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.incomingReported(uuid: uuid, accepted: true, error: error) }
        }
    }

    private func incomingReported(uuid: UUID, accepted: Bool, error: Error?) {
        if let error {
            log.info("incoming call not shown: \(error.localizedDescription, privacy: .public)")
            if accepted, call?.uuid == uuid, let current = teardown(reason: "Missed call.") {
                finish(current, sending: "decline")
            }
            return
        }
        guard accepted else { return provider.reportCall(with: uuid, endedAt: nil, reason: .failed) }
        queryRing(uuid: uuid)
    }

    private func queryRing(uuid: UUID) {
        guard var current = call, current.uuid == uuid else { return }
        for profile in app.profiles {
            guard let session = try? app.borrowSession(for: profile) else { continue }
            current.candidates.append(session)
            listen(to: session)
            Task { [log] in
                do {
                    try await session.send(["type": "invite_query", "call_id": .string(current.callID)])
                } catch {
                    log.error("invite query not sent: \(String(describing: error), privacy: .public)")
                }
            }
        }
        guard !current.candidates.isEmpty else {
            call = current
            return end(uuid: uuid, reason: "No relay connection.", notify: false, cause: .failed)
        }
        current.confirmTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.inviteTimeout)
            guard !Task.isCancelled, let self, let pending = call, pending.uuid == uuid, pending.session == nil else { return }
            end(uuid: uuid, reason: "Could not reach \(peerName).", notify: false, cause: .failed)
        }
        call = current
    }

    private func confirmRing(_ current: ActiveCall, session: RelaySession, reason: String) {
        var confirmed = current
        confirmed.session = session
        confirmed.candidates = []
        confirmed.confirmTimeout?.cancel()
        confirmed.confirmTimeout = nil
        call = confirmed
        for other in current.candidates where other !== session { app.releaseSession(other) }
        let profile = session.profile
        show(profile)
        callReason = String(reason.prefix(200))
        provider.reportCall(with: current.uuid, updated: Self.update(caller: profile.bridgeName))
        if confirmed.accepted { Task { await negotiate(uuid: current.uuid) } }
    }

    private func show(_ profile: RelayProfile) {
        profileID = profile.id
        peerName = profile.bridgeName
        relayLabel = profile.label
    }

    private static func update(caller: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    /// On-device speech recognition when chosen in Settings and available; nil means the bridge transcribes.
    private func startPhoneTranscriber(callID: String, session: RelaySession) async -> PhoneTranscriber? {
        guard app.preferences.speechRecognition == .iPhone, await PhoneTranscriber.availability() == .ready else { return nil }
        let transcriber = PhoneTranscriber { [log] text, elapsed in
            Task {
                do {
                    try await session.send(["type": "transcript", "call_id": .string(callID), "text": .string(text),
                                            "stt_ms": .int(Int64(elapsed))])
                } catch {
                    log.error("transcript not sent")
                }
            }
        }
        do {
            try await transcriber.start()
        } catch {
            log.error("on-device speech recognition unavailable, using the bridge: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        EngineAudioDevice.shared.onMicBuffer = { buffer, _ in transcriber.feed(buffer) }
        return transcriber
    }

    private func waitForAnswer() async throws -> String {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.answerTimeout)
            self?.failAnswer(ProtocolError.timeout)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            if call == nil {
                continuation.resume(throwing: ProtocolError.notConnected)
            } else {
                call?.answer = continuation
            }
        }
    }

    private func failAnswer(_ error: Error) {
        guard let continuation = call?.answer else { return }
        call?.answer = nil
        continuation.resume(throwing: error)
    }

    private func mediaChanged(_ state: WebRTCCall.State, uuid: UUID) {
        guard let current = call, current.uuid == uuid else { return }
        switch state {
        case .connected:
            guard case .connecting = phase else { return }
            ringback.stop()
            phase = .connected(since: Date())
            if !current.incoming { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
            #if targetEnvironment(simulator)
            // The Simulator's CallKit never activates the audio session; start audio ourselves.
            if !RTCAudioSession.sharedInstance().isAudioEnabled {
                try? AVAudioSession.sharedInstance().setActive(true)
                RTCAudioSession.sharedInstance().audioSessionDidActivate(AVAudioSession.sharedInstance())
                RTCAudioSession.sharedInstance().isAudioEnabled = true
                EngineAudioDevice.shared.sessionActivated()
                log.info("simulator: audio started without CallKit activation")
            }
            #endif
            if current.talkMode == .pushToTalk {
                Task { try? await current.session?.send(["type": "ptt", "call_id": .string(current.callID), "down": false]) }
            }
        case .failed:
            end(uuid: uuid, reason: "The audio connection failed.", notify: true)
        case .connecting, .closed:
            break
        }
    }

    /// One consumer per session for its lifetime: the stream ends when the session is stopped.
    private func listen(to session: RelaySession) {
        let key = ObjectIdentifier(session)
        guard pumps[key] == nil else { return }
        pumps[key] = Task { [weak self] in
            for await message in session.messages {
                self?.handle(message, from: session)
            }
            self?.pumps[key] = nil
        }
    }

    private func handle(_ message: [String: JSON], from session: RelaySession) {
        if ChatModel.handles(message) {
            onChatMessage?(message, session)
            return
        }
        if PhoneContextModel.handles(message) {
            onPhoneMessage?(message, session)
            return
        }
        if TaskActivityModel.handles(message) {
            onTaskMessage?(message, session)
            return
        }
        guard let callID = message["call_id"]?.string else { return }
        let type = message["type"]?.string
        guard var current = call else {
            if type == "invite" { ringFromInvite(callID: callID, session: session, reason: message["reason"]?.string ?? "") }
            return
        }
        guard callID == current.callID else { return }
        guard let confirmed = current.session else {
            guard current.candidates.contains(where: { $0 === session }) else { return }
            if type == "invite" {
                confirmRing(current, session: session, reason: message["reason"]?.string ?? "")
            } else if type == "cancel" {
                current.candidates.removeAll { $0 === session }
                call = current
                app.releaseSession(session)
                if current.candidates.isEmpty {
                    end(uuid: current.uuid, reason: "Missed call.", notify: false, cause: .unanswered)
                }
            }
            return
        }
        guard confirmed === session else { return }
        switch type {
        case "answer":
            if let sdp = message["sdp"]?.string {
                current.answer?.resume(returning: sdp)
                current.answer = nil
                call = current
            }
        case "busy":
            end(uuid: current.uuid, reason: "\(peerName) is already on a call.", notify: false)
        case "cancel":
            let cause: CXCallEndedReason = switch message["why"]?.string {
            case "answered_elsewhere": .answeredElsewhere
            case "timeout": .unanswered
            default: .remoteEnded
            }
            end(uuid: current.uuid, reason: "Call ended.", notify: false, cause: cause)
        case "hangup":
            end(uuid: current.uuid, reason: "Call ended.", notify: false)
        case "call_image_ack":
            if message["ok"]?.bool == false { log.info("the bridge refused a picture") }
        case "caption":
            guard let text = message["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return }
            let caption = Caption(fromAgent: message["role"]?.string != "owner", text: String(text.prefix(500)), date: Date())
            captions = Array((captions + [caption]).suffix(Self.maxCaptions))
        case "approval_request":
            guard isConnected, pendingApproval == nil, let id = message["request_id"]?.string, !id.isEmpty,
                  let command = message["command"]?.string, command.count <= Self.maxApprovalText,
                  let details = message["description"]?.string, details.count <= Self.maxApprovalText
            else {
                Task { [log] in
                    log.error("approval request refused")
                    let id = message["request_id"]?.string ?? ""
                    guard !id.isEmpty else { return }
                    try? await confirmed.send(["type": "approval", "call_id": .string(current.callID),
                                               "request_id": .string(id), "choice": "deny"])
                }
                return
            }
            pendingApproval = Approval(id: id, callID: current.callID, command: command, details: details)
        default:
            break
        }
    }

    /// Ends the call locally; `notify` tells the bridge (we hung up or failed).
    private func end(uuid: UUID, reason: String, notify: Bool, cause: CXCallEndedReason? = nil) {
        guard call?.uuid == uuid, let current = teardown(reason: reason) else { return }
        finish(current, sending: notify ? Self.goodbye(current) : nil)
        provider.reportCall(with: uuid, endedAt: Date(), reason: cause ?? (notify ? .failed : .remoteEnded))
    }

    private func teardown(reason: String) -> ActiveCall? {
        guard let current = call else { return nil }
        call = nil
        if case .connected(let since) = phase, let profile = current.session?.profile.id {
            onCallEnded?(profile, Date().timeIntervalSince(since), current.incoming)
        }
        ringback.stop()
        current.confirmTimeout?.cancel()
        if current.incoming { finishedCallIDs = (finishedCallIDs + [current.callID]).suffix(20) }
        current.answer?.resume(throwing: ProtocolError.notConnected)
        current.rtc?.close()
        if let transcriber = current.transcriber {
            EngineAudioDevice.shared.onMicBuffer = nil
            Task { await transcriber.stop() }
        }
        pendingApproval = nil
        captions = []
        isTalking = false
        isMuted = false
        phase = .ended(reason: reason)
        return current
    }

    private static func goodbye(_ call: ActiveCall) -> String {
        call.incoming && !call.accepted ? "decline" : "hangup"
    }

    /// Optionally tells the bridge(s) (`hangup`, `decline`), then gives the relay connections back.
    private func finish(_ current: ActiveCall, sending type: String?) {
        let sessions = current.session.map { [$0] } ?? current.candidates
        Task { [app, log] in
            if let type {
                for session in sessions {
                    do {
                        try await session.send(["type": .string(type), "call_id": .string(current.callID)])
                        log.info("\(type, privacy: .public) sent")
                    } catch {
                        log.error("\(type, privacy: .public) not sent: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            sessions.forEach(app.releaseSession)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ProtocolError.timeout: "Your agent did not answer. Is the bridge running?"
        case ProtocolError.notConnected: "Cannot reach your relay."
        case ProtocolError.relay(let code): "The relay refused the call (\(code))."
        default: "The call could not be set up."
        }
    }

    private func configureAudioSession() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        } catch {
            log.error("audio session configuration failed")
        }
    }
}

/// The provider delivers on the main queue (see `setDelegate(_:queue: .main)`).
extension CallCoordinator: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            if let current = call, let ended = teardown(reason: "Call reset.") {
                finish(ended, sending: Self.goodbye(current))
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let uuid = action.callUUID
        MainActor.assumeIsolated {
            guard call == nil else { return action.fail() }
            configureAudioSession()
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            action.fulfill()
            startOutgoing(uuid: uuid)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            guard var current = call, current.uuid == action.callUUID, current.incoming else { return action.fail() }
            guard AVAudioApplication.shared.recordPermission != .denied else {
                action.fail()
                return end(uuid: current.uuid, reason: "Microphone access is off. Allow it in Settings › Hermes Call.",
                           notify: true, cause: .failed)
            }
            configureAudioSession()
            current.accepted = true
            call = current
            phase = .connecting
            action.fulfill()
            if current.session != nil { Task { await negotiate(uuid: current.uuid) } }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            if let current = call, current.uuid == action.callUUID, let ended = teardown(reason: "Call ended.") {
                finish(ended, sending: Self.goodbye(current))
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            applyMute(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Logger(subsystem: "de.quavon.hermescall", category: "call").info("CallKit activated audio")
        let audio = RTCAudioSession.sharedInstance()
        audio.audioSessionDidActivate(audioSession)
        audio.isAudioEnabled = true
        EngineAudioDevice.shared.sessionActivated()
        MainActor.assumeIsolated {
            if let current = call, !current.incoming, phase == .connecting { ringback.start() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false
        audio.audioSessionDidDeactivate(audioSession)
    }
}
