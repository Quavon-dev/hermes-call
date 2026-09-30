import Foundation
import os
import UIKit
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch side of WatchConnectivity: the latest snapshot from the iPhone, and requests to it.
/// Messages, voice notes and denials wait in WatchConnectivity's queue while the iPhone is out of reach.
@MainActor @Observable
final class WatchModel: NSObject {
    private(set) var snapshot: WatchSnapshot
    private(set) var reachable = false
    var status: String?

    private let log = Logger(subsystem: "de.quavon.hermescall.watchkitapp", category: "link")
    private static let storeKey = "snapshot"

    override init() {
        snapshot = (UserDefaults.standard.data(forKey: Self.storeKey))
            .flatMap { try? JSONDecoder().decode(WatchSnapshot.self, from: $0) } ?? .empty
        still = UserDefaults.standard.data(forKey: Self.stillKey).flatMap(UIImage.init(data:))
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var palette: WatchPalette { WatchPalette(snapshot.palette) }
    /// The iPhone's rendered presence in the agent's colour, once received.
    private(set) var still: UIImage?
    private static let stillKey = "still"

    /// The call runs on the iPhone (audio on the iPhone or its AirPods); the watch only starts it.
    func call() {
        send(WatchRequest(kind: .call), done: "Calling on your iPhone…")
    }

    func sendMessage(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WatchLink.maxText))
        guard !trimmed.isEmpty else { return }
        send(WatchRequest(kind: .message(trimmed)), done: "Sent")
    }

    func deny(_ approval: WatchSnapshot.Approval) {
        send(WatchRequest(kind: .deny(approvalID: approval.id)), done: "Denied")
    }

    /// A recorded voice note goes as a file transfer (queued by WatchConnectivity until the iPhone takes it).
    func sendVoiceNote(_ file: URL, duration: TimeInterval) {
        guard WCSession.default.activationState == .activated else {
            status = "Open Hermes Call on your iPhone."
            return
        }
        let request = WatchRequest(kind: .voice(duration: duration))
        WCSession.default.transferFile(file, metadata: request.dictionary)
        status = WCSession.default.isReachable ? "Voice note sent" : "Voice note waits for your iPhone"
    }

    private func send(_ request: WatchRequest, done: String) {
        switch request.route(activated: WCSession.default.activationState == .activated, reachable: WCSession.default.isReachable) {
        case .unavailable:
            status = "Open Hermes Call on your iPhone."
        case .queued:
            WCSession.default.transferUserInfo(request.dictionary)
            status = "Waits for your iPhone"
        case .live:
            status = nil
            Self.deliver(request.dictionary) { [weak self] ok, error in
                Task { @MainActor in self?.delivered(request, ok: ok, error: error, done: done) }
            }
        }
    }

    private func delivered(_ request: WatchRequest, ok: Bool, error: String?, done: String) {
        if ok {
            status = done
        } else if error == nil, request.canWait {
            // The iPhone went out of reach meanwhile: queue it (same id, so it is not done twice).
            WCSession.default.transferUserInfo(request.dictionary)
            status = "Waits for your iPhone"
        } else {
            status = error ?? "Your iPhone could not do that."
        }
    }

    /// WatchConnectivity calls back on its own queue: the handlers must not be main-actor closures.
    /// `error` nil with `ok` false: the iPhone was not reachable.
    private nonisolated static func deliver(_ message: [String: Any], result: @escaping @Sendable (Bool, String?) -> Void) {
        WCSession.default.sendMessage(message, replyHandler: { reply in
            result(reply["ok"] as? Bool ?? false, reply["error"] as? String ?? "Your iPhone could not do that.")
        }, errorHandler: { _ in
            result(false, nil)
        })
    }

    fileprivate func applyStill(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else { return }
        still = image
        UserDefaults.standard.set(data, forKey: Self.stillKey)
    }

    fileprivate func apply(_ data: Data?) {
        guard let data, let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }
        callState(snapshot.call)
        self.snapshot = snapshot
        UserDefaults.standard.set(data, forKey: Self.storeKey)
        WatchPalette.share(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Taps on the wrist when a call rings, starts and ends on the iPhone.
    fileprivate func callState(_ state: WatchSnapshot.CallState?) {
        guard let cue = WatchCallCue.between(snapshot.call, state) else { return }
        snapshot.call = state
        switch cue {
        case .ringing: WKInterfaceDevice.current().play(.notification)
        case .started: WKInterfaceDevice.current().play(.start)
        case .ended: WKInterfaceDevice.current().play(.stop)
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext[WatchLink.snapshot] as? Data
        let still = session.receivedApplicationContext[WatchLink.still] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.apply(data)
            self.applyStill(still)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchLink.snapshot] as? Data
        let still = applicationContext[WatchLink.still] as? Data
        Task { @MainActor in
            self.apply(data)
            self.applyStill(still)
        }
    }

    /// The call's state, sent at once while the watch app is open.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let raw = message[WatchLink.callState] as? String
        Task { @MainActor in self.callState(raw.flatMap(WatchSnapshot.CallState.init(rawValue:))) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file.fileURL
        if error == nil { try? FileManager.default.removeItem(at: file) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }
}
