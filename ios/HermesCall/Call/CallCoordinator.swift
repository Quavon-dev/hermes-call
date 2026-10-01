import AVFoundation
@preconcurrency import CallKit
import Foundation
import HermesCallCore
import LocalAuthentication
import os
import UIKit
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
        /// The bridge offers "Allow for this session".
        var allowsSession = false
    }

    private(set) var phase: Phase = .idle
    private(set) var isMuted = false
    private(set) var isTalking = false
    /// Speaker, route and interruptions of the call's audio session.
    let audio = CallAudioRoute()
    var isSpeaker: Bool { audio.isSpeaker }
    private(set) var peerName = RelayProfile.defaultAgentName
    /// The relay profile of the current (or last) call, once known.
    private(set) var profileID: UUID?
    private(set) var relayLabel = "relay"
    private(set) var callReason = ""
    var pendingApproval: Approval? { didSet { if pendingApproval?.id != oldValue?.id { approvalStep = .waiting } } }
    private(set) var approvalStep = ApprovalStep.waiting
    /// Face ID / passcode for approvals (a fake in tests).
    var authenticator: any OwnerAuthenticator = DeviceOwnerAuthenticator()
    /// The latest spoken lines of this call (bridge `caption`, or the demo's), newest last.
    var captions: [Caption] { demo?.captions ?? liveCaptions }
    private var liveCaptions: [Caption] = []
    /// The demo agent's simulated call (DemoAgent); no CallKit, no audio.
    private(set) var demo: PresenceDemo?
    private var demoLevels = (agent: 0.0, mic: 0.0)
    private var demoClock: Task<Void, Never>?
    /// Talk mode for the next outgoing call (hold-to-talk on the presence), else the preference.
    private var nextTalkMode: TalkMode?
    /// Same limit as the bridge: longer commands are denied there, never shown cut off.
    static let maxApprovalText = 4000

    let app: AppModel
    private let router: MessageRouter
    private let provider: CXProvider
    private let controller = CXCallController()
    private let ringback = RingbackTone()
    let log = Logger(subsystem: "de.quavon.hermescall", category: "call")
    /// Internal (not private) for the extension files (CallCoordinator+Reconnect).
    var call: ActiveCall?
    /// The call's audio is being moved to a new connection (network change): "Reconnecting…".
    var reconnecting: Bool { demo?.reconnecting ?? liveReconnecting }
    var liveReconnecting = false
    /// Rings that already ended, so a late `invite` (e.g. the reply to `invite_query`) cannot ring again.
    private var finishedCallIDs: [String] = []
    /// A connected call ended: (relay profile, duration, incoming), for the chat's call entries.
    var onCallEnded: ((UUID, TimeInterval, Bool) -> Void)?

    struct ActiveCall {
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
        /// Set once negotiated: re-offers on a network change when the bridge lists `call_resume`.
        var reconnect: CallReconnect?
        var reconnectClock: Task<Void, Never>?
        var reoffering = false
    }

    static let answerTimeout: Duration = .seconds(20)
    static let inviteTimeout: Duration = .seconds(15)

    init(app: AppModel, router: MessageRouter = MessageRouter()) {
        self.app = app
        self.router = router
        provider = CXProvider(configuration: Self.configuration(includeInRecents: app.preferences.includeInRecents))
        super.init()
        provider.setDelegate(self, queue: .main)
        router.onCall = { [weak self] message, session in self?.handle(message, from: session) }
        app.onSessionCreated = { [weak router] session in router?.listen(to: session) }
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    func applyRecentsPreference() {
        provider.configuration = Self.configuration(includeInRecents: app.preferences.includeInRecents)
    }

    var inCall: Bool { call != nil || demo != nil }
    var isDemoCall: Bool { demo != nil }

    func telemetry() async -> CallTelemetry {
        if demo != nil { return CallTelemetry(mic: isMuted ? 0 : demoLevels.mic, agent: demoLevels.agent) }
        return await call?.rtc?.telemetry() ?? CallTelemetry()
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
        if demo != nil { return Float(demoLevels.agent) }
        return call?.rtc?.usesEngineAudio == true ? EngineAudioDevice.shared.agentSpectrum.currentLevel : nil
    }

    /// Voice levels (agent, owner) for the presence, read every frame: the audio engine's own analysis,
    /// the demo's simulation, or with the legacy audio device WebRTC's statistics (refreshed at most four
    /// times a second). nil while the call is not connected.
    func liveLevels() -> (agent: Double, mic: Double)? {
        guard isConnected else { return nil }
        if demo != nil { return (demoLevels.agent, isMuted ? 0 : demoLevels.mic) }
        guard let rtc = call?.rtc else { return nil }
        if rtc.usesEngineAudio {
            let device = EngineAudioDevice.shared
            return (Double(device.agentSpectrum.currentLevel), isMuted ? 0 : Double(device.micSpectrum.currentLevel))
        }
        if Date().timeIntervalSince(statsRead) > 0.25 {
            statsRead = Date()
            Task { stats = await rtc.telemetry() }
        }
        return (stats.agent, isMuted ? 0 : stats.mic)
    }

    @ObservationIgnored private var stats = CallTelemetry()
    @ObservationIgnored private var statsRead = Date.distantPast

    // MARK: user actions

    func startCall(talkMode: TalkMode? = nil) async {
        guard !inCall, let profile = app.activeProfile else { return }
        if profile.isDemo || PresenceDemo.forced { return startDemoCall(profile) }
        guard app.requireConsent() else { return }
        nextTalkMode = talkMode
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .ended(reason: "Microphone access is off.")
            app.error = .microphoneDenied
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
        if demo != nil { return endDemoCall() }
        guard let call else { return }
        let uuid = call.uuid
        Self.request(controller, CXEndCallAction(call: uuid)) { [weak self] in
            Task { @MainActor in self?.end(uuid: uuid, reason: "Call ended.", notify: true) }
        }
    }

    func setMuted(_ muted: Bool) {
        if demo != nil { return isMuted = muted }
        guard let call else { return }
        Self.request(controller, CXSetMutedCallAction(call: call.uuid, muted: muted)) { [weak self] in
            Task { @MainActor in self?.applyMute(muted) }
        }
    }

    private func applyMute(_ muted: Bool) {
        isMuted = muted
        if let current = call { updateMic(current) }
    }

    /// The microphone (and on-device transcription) is open only when not muted and, in
    /// push-to-talk, while the button is held.
    func updateMic(_ current: ActiveCall) {
        let open = !isMuted && (current.talkMode == .handsFree || isTalking)
        current.rtc?.micEnabled = open
        current.transcriber?.setGated(!open)
    }

    func toggleSpeaker() {
        audio.toggleSpeaker()
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
        var sent = imagesSent.flatMap { $0.callID == current.callID ? $0 : nil } ?? (current.callID, 0, .distantPast)
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
        let used = imagesSent.flatMap { $0.callID == current.callID ? $0.count : nil } ?? 0
        return Self.maxImagesPerCall - used
    }

    /// Push-to-talk: the microphone is live only while the button is held.
    func setTalking(_ down: Bool) {
        guard let current = call, current.talkMode == .pushToTalk, down != isTalking else { return }
        isTalking = down
        updateMic(current)
        Task { try? await current.session?.send(["type": "ptt", "call_id": .string(current.callID), "down": .bool(down)]) }
    }

    /// Approving needs Face ID / passcode; denying never does. A cancelled Face ID keeps the request open
    /// (Try again / Deny) instead of denying it. `session` only when the bridge offered it.
    func answerApproval(approve: Bool) async {
        await answerApproval(approve ? .once : .deny)
    }

    func answerApproval(_ choice: ApprovalChoice) async {
        guard let approval = pendingApproval, approvalStep != .confirming, let current = call, approval.callID == current.callID,
              choice != .session || approval.allowsSession
        else { return }
        if choice != .deny {
            approvalStep = .confirming
            let check = await authenticator.confirm(reason: ApprovalStep.reason)
            guard pendingApproval?.id == approval.id else { return }
            guard check == .confirmed else { return approvalStep = ApprovalStep.after(check) }
        }
        guard pendingApproval?.id == approval.id, call?.callID == approval.callID else { return }
        pendingApproval = nil
        try? await current.session?.send([
            "type": "approval", "call_id": .string(approval.callID), "request_id": .string(approval.id),
            "choice": .string(choice.rawValue),
        ])
    }

    // MARK: demo call

    /// The demo agent "answers" at once: captions and voice levels are simulated on this iPhone.
    private func startDemoCall(_ profile: RelayProfile) {
        let simulated = PresenceDemo(lines: DemoAgent.callLines)
        simulated.start()
        demo = simulated
        show(profile)
        callReason = ""
        isMuted = false
        phase = .connected(since: Date())
        demoClock = Task { [weak self] in
            while !Task.isCancelled, let self, let demo = self.demo {
                self.demoLevels = demo.sample()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func endDemoCall() {
        guard let simulated = demo else { return }
        demoClock?.cancel()
        demoClock = nil
        if let since = simulated.since, let profile = profileID { onCallEnded?(profile, Date().timeIntervalSince(since), false) }
        simulated.end()
        demo = nil
        demoLevels = (0, 0)
        isMuted = false
        phase = .ended(reason: "Call ended.")
    }

    // MARK: call flow    // MARK: call flow

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
        router.listen(to: session)
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
            rtc.onStateChange = { [weak self, weak rtc] state in
                guard let rtc else { return }
                self?.mediaChanged(state, uuid: uuid, rtc: rtc)
            }
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
            call?.reconnect = CallReconnect(supported: await session.bridgeInfo?.supports(CallReconnect.cap) == true)
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
        let profiles = app.realProfiles
        let name = Self.ringName(profiles.map(\.bridgeName))
        let accepted = callID.map { !finishedCallIDs.contains($0) } == true && !inCall && !profiles.isEmpty
        if accepted, let callID {
            call = ActiveCall(uuid: uuid, callID: callID, incoming: true, talkMode: app.preferences.talkMode)
            peerName = name
            relayLabel = profiles.count == 1 ? profiles[0].label : "relay"
            profileID = profiles.count == 1 ? profiles[0].id : nil
            callReason = ""
            phase = .ringing
        }
        Self.report(provider, incoming: uuid, update: Self.update(caller: name)) { [weak self] error in
            completion()
            Task { @MainActor in self?.incomingReported(uuid: uuid, accepted: accepted, error: error) }
        }
    }

    /// While the app is open, the bridge's E2E `invite` rings directly (no push needed).
    private func ringFromInvite(callID: String, session incoming: RelaySession, reason: String) {
        guard let uuid = Self.callUUID(callID), !finishedCallIDs.contains(callID), demo == nil,
              let session = try? app.borrowSession(for: incoming.profile) else { return }
        guard session === incoming else { return app.releaseSession(session) }
        call = ActiveCall(uuid: uuid, callID: callID, incoming: true, talkMode: app.preferences.talkMode, session: session)
        show(session.profile)
        callReason = String(reason.prefix(200))
        phase = .ringing
        Self.report(provider, incoming: uuid, update: Self.update(caller: session.profile.bridgeName)) { [weak self] error in
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
        for profile in app.realProfiles {
            guard let session = try? app.borrowSession(for: profile) else { continue }
            current.candidates.append(session)
            router.listen(to: session)
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

    func waitForAnswer(timeout limit: Duration = answerTimeout) async throws -> String {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
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

    /// Events of a replaced connection (after a re-offer) are ignored.
    func mediaChanged(_ state: WebRTCCall.State, uuid: UUID, rtc: WebRTCCall) {
        guard let current = call, current.uuid == uuid, current.rtc === rtc else { return }
        switch state {
        case .connected:
            if isConnected { return reconnectEvent { $0.mediaConnected() } }
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
            guard isConnected, current.reconnect != nil else {
                return end(uuid: uuid, reason: CallReconnect.EndReason.mediaFailed.text, notify: true)
            }
            reconnectEvent { $0.mediaFailed(now: Date()) }
        case .disconnected:
            if isConnected { reconnectEvent { $0.mediaDisconnected(now: Date()) } }
        case .connecting, .closed:
            break
        }
    }

    /// Call signaling from the router (chat, phone and task messages go elsewhere).
    private func handle(_ message: [String: JSON], from session: RelaySession) {
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
            let lost = message["why"]?.string == "connection_lost"
            end(uuid: current.uuid, reason: lost ? CallReconnect.EndReason.connectionLost.text : "Call ended.", notify: false)
        case "call_image_ack":
            if message["ok"]?.bool == false { log.info("the bridge refused a picture") }
        case "caption":
            guard let text = message["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return }
            let caption = Caption(fromAgent: message["role"]?.string != "owner", text: String(text.prefix(500)), date: Date())
            liveCaptions = Array((liveCaptions + [caption]).suffix(Self.maxCaptions))
        case "approval_request":
            receiveApproval(message, call: current, session: confirmed)
        default:
            break
        }
    }

    private func receiveApproval(_ message: [String: JSON], call current: ActiveCall, session: RelaySession) {
        guard isConnected, pendingApproval == nil, let id = message["request_id"]?.string, !id.isEmpty,
              let command = message["command"]?.string, command.count <= Self.maxApprovalText,
              let details = message["description"]?.string, details.count <= Self.maxApprovalText
        else {
            Task { [log] in
                log.error("approval request refused")
                let id = message["request_id"]?.string ?? ""
                guard !id.isEmpty else { return }
                try? await session.send(["type": "approval", "call_id": .string(current.callID),
                                         "request_id": .string(id), "choice": "deny"])
            }
            return
        }
        pendingApproval = Approval(id: id, callID: current.callID, command: command, details: details,
                                   allowsSession: ApprovalChoice.allowsSession(message))
    }

    /// Ends the call locally; `notify` tells the bridge (we hung up or failed).
    func end(uuid: UUID, reason: String, notify: Bool, cause: CXCallEndedReason? = nil) {
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
        current.reconnectClock?.cancel()
        liveReconnecting = false
        if current.incoming { finishedCallIDs = (finishedCallIDs + [current.callID]).suffix(20) }
        current.answer?.resume(throwing: ProtocolError.notConnected)
        current.rtc?.close()
        if let transcriber = current.transcriber {
            EngineAudioDevice.shared.onMicBuffer = nil
            Task { await transcriber.stop() }
        }
        pendingApproval = nil
        liveCaptions = []
        isTalking = false
        isMuted = false
        audio.reset()
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
            guard !inCall else { return action.fail() }
            audio.configure()
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
                app.error = .microphoneDenied
                return end(uuid: current.uuid, reason: "Microphone access is off.", notify: true, cause: .failed)
            }
            guard app.mayShare else {
                action.fail()
                app.error = .consentRequired
                return end(uuid: current.uuid, reason: "Sharing with your agent is not allowed yet.", notify: true, cause: .failed)
            }
            audio.configure()
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
