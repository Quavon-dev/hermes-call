import Foundation
import HermesCallCore
import os
import UIKit
import WatchConnectivity

/// The iPhone side of the Apple Watch app. The watch has no relay keys: the iPhone sends it the active
/// agent's latest messages (text only if "Show message text in notifications" is on), a pending approval
/// and the call's state, and does what it asks — start a call here, send a dictated message or a voice
/// note, deny an approval. Updates go out whenever the history changes, also in the background.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var app: AppModel?
    private var chat: ChatModel?
    private var calls: CallCoordinator?
    private var lastSent: WatchSnapshot?
    private var lastCall: WatchSnapshot.CallState?
    private var publishing: Task<Void, Never>?
    /// Requests done already (a live request whose reply got lost comes again from the queue).
    private var handled = HandledRequests()
    private static let handledKey = "watch.handledRequests"
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "watch")

    func configure(app: AppModel, chat: ChatModel, calls: CallCoordinator) {
        self.app = app
        self.chat = chat
        self.calls = calls
        for id in UserDefaults.standard.stringArray(forKey: Self.handledKey) ?? [] { _ = handled.insert(id) }
        chat.onHistoryChanged = { [weak self] profile in
            if profile == self?.app?.activeProfile?.id { self?.publish() }
        }
        observe()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Publishes again when the agent, the approval, the call or the text preference changes.
    private func observe() {
        withObservationTracking {
            _ = (app?.activeProfile, app?.profiles.count, app?.preferences.showMessageText, chat?.pendingApproval, calls?.phase)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.observe()
            }
        }
    }

    /// Sends the current snapshot when it changed (and a watch app is installed).
    func publish() {
        publishing?.cancel()
        publishing = Task { await publishNow() }
    }

    private func publishNow() async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled,
              let app, let chat, let calls else { return }
        let profile = app.activeProfile
        let recent = if let profile { await chat.recentMessages(profile.id, limit: 30) } else { [ChatMessage]() }
        guard !Task.isCancelled else { return }
        let snapshot = Self.snapshot(agentName: profile?.bridgeName ?? RelayProfile.defaultAgentName,
                                     palette: profile?.agentPalette.rawValue ?? "gold", paired: !app.profiles.isEmpty, messages: recent,
                                     showText: app.preferences.showMessageText, approval: chat.pendingApproval, phase: calls.phase)
        sendCallState(snapshot.call)
        guard snapshot != lastSent, let data = try? JSONEncoder().encode(snapshot) else { return }
        var context: [String: Any] = [WatchLink.snapshot: data]
        if let still = Self.still(snapshot.palette), still.count < 50_000 { context[WatchLink.still] = still }
        do {
            try WCSession.default.updateApplicationContext(context)
            lastSent = snapshot
        } catch {
            log.error("watch update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// While the watch app is open: the call's state at once, for the wrist haptics.
    private func sendCallState(_ state: WatchSnapshot.CallState?) {
        guard state != lastCall else { return }
        lastCall = state
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchLink.callState: state?.rawValue ?? "none"], replyHandler: nil, errorHandler: nil)
    }

    /// What the watch shows (text only when the owner shows message text in notifications).
    static func snapshot(agentName: String, palette: String, paired: Bool, messages: [ChatMessage], showText: Bool,
                         approval: ChatApproval?, phase: CallCoordinator.Phase) -> WatchSnapshot {
        let shown = messages.filter { $0.role != .system }.suffix(WatchSnapshot.maxMessages).map { message in
            WatchSnapshot.Message(id: message.id, fromAgent: message.role == .agent,
                                  text: showText ? String(message.preview.prefix(300)) : "New message", date: message.date)
        }
        let call: WatchSnapshot.CallState? = switch phase {
        case .ringing: .ringing
        case .connecting: .connecting
        case .connected: .connected
        case .idle, .ended: nil
        }
        return WatchSnapshot(agentName: agentName, palette: palette, paired: paired, messages: Array(shown),
                             approval: approval.map { WatchSnapshot.approval(id: $0.id, command: $0.command) }, call: call)
    }

    /// The same rendered presence as the widgets, small enough for the application context (≤ 65 KB).
    private static func still(_ palette: String) -> Data? {
        guard let agent = AgentPalette(rawValue: palette),
              let image = UIImage(contentsOfFile: SharedContainer.presenceStillURL(agent).path) else { return nil }
        let size = CGSize(width: 150, height: 150)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Does what the watch asked; `voice`: the note's bytes for a voice request.
    fileprivate func perform(_ request: WatchRequest, voice: Data? = nil) async -> (ok: Bool, error: String?) {
        guard let app, let chat, let calls, app.activeProfile != nil else { return (false, "Pair a relay first.") }
        guard handled.insert(request.id) else { return (true, nil) }
        UserDefaults.standard.set(handled.ids, forKey: Self.handledKey)
        switch request.kind {
        case .call:
            guard !calls.inCall else { return (false, "Already on a call.") }
            await calls.startCall()
            return (calls.inCall, calls.inCall ? nil : "The call could not start.")
        case .message(let text):
            await chat.send(text: text)
            return (true, nil)
        case .deny(let approvalID):
            await chat.answerApproval(approve: false, id: approvalID)
            return (true, nil)
        case .voice(let duration):
            guard let voice else { return (false, "The voice note did not arrive.") }
            await chat.send(text: "", files: [OutgoingFile(kind: .voice, name: "Voice note.m4a", mime: "audio/mp4", data: voice,
                                                           duration: duration)])
            return (true, nil)
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A different watch was paired: activate again for it.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.publish()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastCall = nil
            self.publish()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let request = WatchRequest(message)
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            guard let request else { return reply(["ok": false]) }
            let (ok, error) = await self.perform(request)
            var answer: [String: Any] = ["ok": ok]
            if let error { answer["error"] = error }
            reply(answer)
        }
    }

    /// Queued while the iPhone was out of reach (messages, denials).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let request = WatchRequest(userInfo) else { return }
        Task { @MainActor in _ = await self.perform(request) }
    }

    /// A voice note recorded on the watch. The file is gone after this returns: read it now.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let request = WatchRequest(file.metadata ?? [:]), case .voice = request.kind,
              let data = try? Data(contentsOf: file.fileURL), data.count <= Blob.maxPlaintext else { return }
        Task { @MainActor in _ = await self.perform(request, voice: data) }
    }
}
