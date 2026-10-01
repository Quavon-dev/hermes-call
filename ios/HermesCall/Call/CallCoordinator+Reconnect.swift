// SPDX-License-Identifier: MIT
import Foundation
import HermesCallCore

/// C1: a call survives a network handover. When the audio connection breaks, the call screen shows
/// "Reconnecting…", CallKit's call stays up, and a new connection is offered to the bridge under the same
/// call id (`CallReconnect` decides when); the bridge keeps the conversation. Bridges without
/// `call_resume` end the call as before.
extension CallCoordinator {
    /// The phone moved to another network (Wi-Fi ↔ cellular): the current path is gone.
    /// The call's relay socket may still look open on the old path, so it is replaced first: signaling
    /// (a re-offer, its answer, a hangup) must not go out on a dead connection. The audio connection is
    /// only replaced if it stopped working (the bridge drops its side when a re-offer arrives).
    func networkChanged() {
        guard let session = call?.session else { return }
        let uuid = call?.uuid
        Task {
            await session.reconnectNow(force: true)
            guard call?.uuid == uuid, isConnected, call?.reconnect != nil else { return }
            log.info("network changed during the call")
            _ = await mediaHealthy()  // the baseline for the check after the grace
            reconnectEvent { $0.networkChanged(now: Date()) }
        }
    }

    /// The call's connection is connected and audio from the bridge keeps arriving (packets since the last
    /// sample; the bridge sends audio, silence included, all the time).
    func mediaHealthy() async -> Bool {
        guard let rtc = call?.rtc, rtc.state == .connected else { return false }
        let id = ObjectIdentifier(rtc)
        guard let packets = await rtc.telemetry().inboundPackets, call?.rtc === rtc else { return false }
        let previous = call?.inboundSample
        call?.inboundSample = (id, packets)
        guard let previous, previous.rtc == id else { return packets > 0 }
        return packets > previous.packets
    }

    /// Feeds one event to the call's reconnect state and carries out what it decides.
    func reconnectEvent(_ event: (inout CallReconnect) -> CallReconnect.Action) {
        guard var current = call, var machine = current.reconnect else { return }
        let action = event(&machine)
        current.reconnect = machine
        call = current
        liveReconnecting = machine.isReconnecting
        if machine.needsClock { startReconnectClock() }
        perform(action, uuid: current.uuid)
    }

    private func perform(_ action: CallReconnect.Action, uuid: UUID) {
        switch action {
        case .none: break
        case .recovered:
            log.info("call audio is back")
            call?.reconnectClock?.cancel()
            call?.reconnectClock = nil
        case .reoffer: Task { await reoffer(uuid: uuid) }
        case .end(let reason):
            log.info("giving up on the call's connection")
            end(uuid: uuid, reason: reason.text, notify: true)
        }
    }

    /// Ticks about once a second while reconnecting (the grace before a re-offer, retries, the 20 s limit)
    /// or while a network change's health check is due.
    private func startReconnectClock() {
        guard let current = call, current.reconnectClock == nil else { return }
        let uuid = current.uuid
        call?.reconnectClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.call?.uuid == uuid else { return }
                let healthy = await self.mediaHealthy()
                guard !Task.isCancelled, self.call?.uuid == uuid else { return }
                self.reconnectEvent { $0.tick(now: Date(), healthy: healthy) }
                if self.call?.reconnect?.needsClock != true {
                    self.call?.reconnectClock = nil
                    return
                }
            }
        }
    }

    /// A new connection for the same call id; the old one is closed once the bridge answered.
    private func reoffer(uuid: UUID) async {
        guard let current = call, current.uuid == uuid, !current.reoffering, let session = current.session else { return }
        call?.reoffering = true
        defer { if call?.uuid == uuid { call?.reoffering = false } }
        log.info("offering a new connection for the call")
        var candidate: WebRTCCall?
        do {
            // Short limits: a lost offer or answer is retried within the reconnect window (CallReconnect).
            let limit = CallReconnect.answerTimeout
            try await session.waitUntilConnected(timeout: limit)
            let turn = try await session.request(["t": "turn"], timeout: limit)
            let rtc = try WebRTCCall(turn: turn, relayHost: session.profile.relay.host, onDeviceSpeech: current.transcriber != nil)
            candidate = rtc
            rtc.onStateChange = { [weak self, weak rtc] state in
                guard let rtc else { return }
                self?.mediaChanged(state, uuid: uuid, rtc: rtc)
            }
            let offer = try await rtc.makeOffer()
            guard call?.uuid == uuid else { return rtc.close() }
            var body: [String: JSON] = ["type": "offer", "call_id": .string(current.callID), "sdp": .string(offer)]
            if current.transcriber != nil { body["stt"] = "device" }
            try await session.send(body)
            let answer = try await waitForAnswer(timeout: .seconds(limit))
            guard var latest = call, latest.uuid == uuid else { return rtc.close() }
            let old = latest.rtc
            latest.rtc = rtc
            call = latest
            old?.close()
            updateMic(latest)
            try await rtc.accept(answer: answer)
            log.info("new connection negotiated")
        } catch {
            log.error("re-offer failed: \(String(describing: error), privacy: .public)")
            // A connection that never became the call's (no answer in time) would otherwise stay open.
            if let candidate, call?.rtc !== candidate { candidate.close() }
            // The re-offer never reached the bridge (no relay, no TURN) and the old connection still carries
            // audio: the call is fine, so "Reconnecting…" ends instead of running into the 20 s limit.
            if call?.uuid == uuid, await mediaHealthy() {
                reconnectEvent { $0.mediaConnected() }
            } else {
                reconnectEvent { $0.reofferFailed(now: Date()) }
            }
        }
    }
}
