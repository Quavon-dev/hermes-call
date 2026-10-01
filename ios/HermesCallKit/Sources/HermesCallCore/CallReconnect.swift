// SPDX-License-Identifier: MIT
import Foundation

/// When a call's audio connection breaks (network handover, Wi-Fi → cellular), the phone sends a new
/// offer for the same call id and the bridge moves the call to a new connection, keeping the conversation
/// (docs/protocol.md, "Call resume"). Only with bridges that list `call_resume`; others end the call on
/// a failed connection, as before. CallKit's call stays up while this runs.
///
/// Pure state: the caller feeds events and a clock tick (about once a second) and carries out the action.
public struct CallReconnect: Sendable, Equatable {
    public enum EndReason: Sendable, Equatable {
        case mediaFailed, connectionLost

        public var text: String {
            switch self {
            case .mediaFailed: "The audio connection failed."
            case .connectionLost: "Connection lost. The call could not be resumed."
            }
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Build a new connection and send an offer with the same call id.
        case reoffer
        /// The audio is back ("Reconnecting…" goes away).
        case recovered
        case end(EndReason)
    }

    public static let cap = "call_resume"
    /// Give up this long after the audio broke (the bridge waits as long).
    public static let window: TimeInterval = 20
    /// libwebrtc's `disconnected` often heals by itself within a moment; re-offer only after this.
    public static let disconnectGrace: TimeInterval = 2
    /// A re-offer that brought no audio is repeated after this.
    public static let retryInterval: TimeInterval = 6
    /// How long a re-offer waits for the bridge's answer: shorter than the retry interval, so a lost offer
    /// or answer costs one attempt, not the whole window.
    public static let answerTimeout: TimeInterval = 5
    /// A re-offer that failed (no relay, no answer) is repeated after this short pause.
    public static let retryAfterFailure: TimeInterval = 1

    public let supported: Bool
    /// Since when the audio is gone (nil: the call is fine).
    public private(set) var brokenSince: Date?
    private var lastOffer: Date?
    private var ended = false

    public init(supported: Bool) {
        self.supported = supported
    }

    public var isReconnecting: Bool { brokenSince != nil && !ended }
    public var needsClock: Bool { isReconnecting }

    /// ICE `disconnected`: may heal by itself; "Reconnecting…" shows, the re-offer waits for the grace.
    public mutating func mediaDisconnected(now: Date) -> Action {
        guard supported, !ended else { return .none }
        if brokenSince == nil { brokenSince = now }
        return .none
    }

    /// The connection failed for good: re-offer now (or end, without resume support).
    public mutating func mediaFailed(now: Date) -> Action {
        guard !ended else { return .none }
        guard supported else { return finish(.mediaFailed) }
        if brokenSince == nil { brokenSince = now }
        return offer(now: now)
    }

    /// The phone moved to another network during the call: the old path is gone, re-offer right away.
    public mutating func networkChanged(now: Date) -> Action {
        guard supported, !ended else { return .none }
        if brokenSince == nil { brokenSince = now }
        return offer(now: now)
    }

    /// The (new) connection carries audio.
    public mutating func mediaConnected() -> Action {
        guard brokenSince != nil, !ended else { return .none }
        brokenSince = nil
        lastOffer = nil
        return .recovered
    }

    /// Building or sending the re-offer failed (no relay yet, no answer in time): the next tick after
    /// `retryAfterFailure` tries again.
    public mutating func reofferFailed(now: Date) -> Action {
        lastOffer = now.addingTimeInterval(Self.retryAfterFailure - Self.retryInterval)
        return .none
    }

    public mutating func tick(now: Date, healthy: Bool = false) -> Action {
        guard let since = brokenSince, !ended else { return .none }
        if now.timeIntervalSince(since) >= Self.window { return finish(.connectionLost) }
        if let lastOffer {
            return now.timeIntervalSince(lastOffer) >= Self.retryInterval ? offer(now: now) : .none
        }
        return now.timeIntervalSince(since) >= Self.disconnectGrace ? offer(now: now) : .none
    }

    private mutating func offer(now: Date) -> Action {
        if let lastOffer, now.timeIntervalSince(lastOffer) < Self.retryInterval { return .none }
        lastOffer = now
        return .reoffer
    }

    private mutating func finish(_ reason: EndReason) -> Action {
        ended = true
        return .end(reason)
    }
}
