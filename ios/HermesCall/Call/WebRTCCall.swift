import Foundation
import HermesCallCore
@preconcurrency import WebRTC

struct CallTelemetry: Sendable, Equatable {
    var mic = 0.0
    var agent = 0.0
    var rttMs: Double?
}

/// One audio-only WebRTC connection to the bridge.
///
/// Relay-only ICE: the phone only ever talks to the user's own TURN server, so the
/// bridge never learns the phone's IP and the phone never learns the home IP.
@MainActor
final class WebRTCCall: NSObject {
    enum State: Equatable { case connecting, connected, disconnected, failed, closed }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    /// Audio through `EngineAudioDevice` (voice spectrum, on-device speech recognition). The default for
    /// every call; launch with `-legacyAudioDevice YES` to fall back to WebRTC's own audio unit.
    private static let engineFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: EngineAudioDevice.shared)
    }()

    private let peer: RTCPeerConnection
    private let delegate: PeerDelegate
    private let audioTrack: RTCAudioTrack
    private var gatheringDone: CheckedContinuation<Void, Never>?
    private var gatheringComplete = false
    var onStateChange: ((State) -> Void)?

    /// Only TURN on the relay's own host: a relay must not route the phone's media (and IP) elsewhere.
    static func isRelayTURN(_ url: String, host: String) -> Bool { TURNServers.isRelayTURN(url, host: host) }

    /// Whether this call's audio runs through `EngineAudioDevice` (so the spectrum is real).
    let usesEngineAudio: Bool

    static var engineAudioEnabled: Bool { !UserDefaults.standard.bool(forKey: "legacyAudioDevice") }

    init(turn: JSON, relayHost: String, onDeviceSpeech: Bool = false) throws {
        usesEngineAudio = onDeviceSpeech || Self.engineAudioEnabled
        let factory = usesEngineAudio ? Self.engineFactory : Self.factory
        // Every URL on the relay's host: `turn:` over UDP and TCP and, where offered, `turns:` (TLS on 5349).
        let servers = try TURNServers(reply: turn, relayHost: relayHost)
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: servers.urls, username: servers.username, credential: servers.credential)]
        config.iceTransportPolicy = .relay
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let delegate = PeerDelegate()
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw ProtocolError.unexpected("could not create the audio connection")
        }
        self.peer = peer
        self.delegate = delegate
        audioTrack = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "mic")
        super.init()
        delegate.owner = self
        peer.add(audioTrack, streamIds: ["hermescall"])
    }

    var micEnabled: Bool {
        get { audioTrack.isEnabled }
        set { audioTrack.isEnabled = newValue }
    }

    /// Complete (non-trickle) SDP offer.
    func makeOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)
        await waitForGathering(timeout: 10)
        guard let sdp = peer.localDescription?.sdp else { throw ProtocolError.unexpected("no local description") }
        return sdp
    }

    func accept(answer sdp: String) async throws {
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    /// Live levels (0…1) of the microphone and the agent's voice, and the link round-trip time.
    func telemetry() async -> CallTelemetry {
        await withCheckedContinuation { continuation in
            Self.statistics(of: peer) { continuation.resume(returning: $0) }
        }
    }

    /// libwebrtc answers on its signaling thread: the callback is made outside the main actor, so Swift never
    /// treats it as main-actor code (which traps when another thread runs it).
    private nonisolated static func statistics(of peer: RTCPeerConnection, done: @escaping @Sendable (CallTelemetry) -> Void) {
        peer.statistics { report in
            var telemetry = CallTelemetry()
            for stat in report.statistics.values {
                let level = (stat.values["audioLevel"] as? NSNumber)?.doubleValue
                switch stat.type {
                case "media-source": telemetry.mic = level ?? telemetry.mic
                case "inbound-rtp" where stat.values["kind"] as? String == "audio": telemetry.agent = level ?? telemetry.agent
                case "candidate-pair" where stat.values["state"] as? String == "succeeded":
                    if let rtt = (stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue { telemetry.rttMs = rtt * 1000 }
                default: break
                }
            }
            done(telemetry)
        }
    }

    func close() {
        audioTrack.isEnabled = false
        peer.close()
    }

    private func waitForGathering(timeout: TimeInterval) async {
        if gatheringComplete { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finishGathering()
        }
        await withCheckedContinuation { gatheringDone = $0 }
        timer.cancel()
    }

    fileprivate func finishGathering() {
        gatheringComplete = true
        gatheringDone?.resume()
        gatheringDone = nil
    }

    fileprivate func connectionChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected: onStateChange?(.connected)
        case .disconnected: onStateChange?(.disconnected)
        case .failed: onStateChange?(.failed)
        case .closed: onStateChange?(.closed)
        default: break
        }
    }
}

/// libwebrtc calls delegates on its signaling thread; hop to the main actor.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var owner: WebRTCCall?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak owner] in owner?.finishGathering() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak owner] in owner?.connectionChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
