import CoreGraphics
import Foundation
import HermesCallCore

/// What the owner did on the presence.
enum PresenceGesture: Equatable {
    case tapHeart
    case holdBegan
    case holdEnded
    case tapRing(Int)
    case tapSpace
    case swipeUp
    case swipeDown
    /// Sideways next to the sphere: the next / previous paired agent.
    case swipeLeft
    case swipeRight
    case longPressSpace(CGPoint)
}

/// What the app does about it.
enum PresenceAction: Equatable {
    case startCall(TalkMode)
    case interrupt
    case beginTalking
    case endTalking
    case openHistory
    case endCall
    case openMenu(CGPoint)
    case showResults
    case showRequests
    /// The tasks ring: offer to stop the agent.
    case offerStop
    /// Switch to the agent `step` places away (+1 next, −1 previous).
    case switchAgent(Int)
    case none
}

enum PresenceIntent {
    /// The gesture map (docs: M8 plan). Pure, so it is unit-tested.
    static func action(for gesture: PresenceGesture, inCall: Bool, talkMode: TalkMode?, canCall: Bool,
                       ringKind: PresenceRingKind? = nil) -> PresenceAction {
        switch gesture {
        case .tapHeart:
            if inCall { return .interrupt }
            return canCall ? .startCall(.handsFree) : .none
        case .holdBegan:
            if inCall { return talkMode == .pushToTalk ? .beginTalking : .interrupt }
            return canCall ? .startCall(.pushToTalk) : .none
        case .holdEnded:
            return inCall && talkMode == .pushToTalk ? .endTalking : .none
        case .tapRing:
            switch ringKind {
            case .messages: return .openHistory
            case .requests: return .showRequests
            case .results: return .showResults
            case .tasks: return .offerStop
            default: return inCall ? .interrupt : (canCall ? .startCall(.handsFree) : .none)
            }
        case .tapSpace: return .none
        case .swipeUp: return .openHistory
        case .swipeDown: return inCall ? .endCall : .none
        case .swipeLeft: return inCall ? .none : .switchAgent(1)
        case .swipeRight: return inCall ? .none : .switchAgent(-1)
        case .longPressSpace(let point): return .openMenu(point)
        }
    }
}

/// Sorts one touch into tap / hold / spin / swipe. Feed it the touch; it answers what happened.
struct PresenceTouch {
    enum Kind: Equatable { case pending, holding, spinning, swiping, done }

    static let slop: CGFloat = 10
    static let holdSeconds = 0.42

    /// Holding the sphere (push to talk) starts quickly; the menu on empty space waits as long as the owner chose.
    static func holdDelay(onSphere: Bool, menuHold: MenuHold) -> Double {
        onSphere ? holdSeconds : menuHold.seconds
    }
    static let swipeDistance: CGFloat = 70

    let start: CGPoint
    /// Where the touch began: the heart (tap/hold = talk), the rest of the sphere (spin), or empty space.
    let onHeart: Bool
    let onSphere: Bool
    private(set) var kind = Kind.pending
    private(set) var last: CGPoint

    init(at point: CGPoint, onHeart: Bool, onSphere: Bool) {
        start = point
        last = point
        self.onHeart = onHeart
        self.onSphere = onSphere
    }

    /// Returns the drag delta while spinning.
    mutating func move(to point: CGPoint) -> CGSize? {
        defer { last = point }
        switch kind {
        case .pending:
            guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { return nil }
            kind = onSphere ? .spinning : .swiping
            return kind == .spinning ? CGSize(width: point.x - start.x, height: point.y - start.y) : nil
        case .spinning:
            return CGSize(width: point.x - last.x, height: point.y - last.y)
        default:
            return nil
        }
    }

    /// The finger rested long enough without moving.
    mutating func holdElapsed() -> PresenceGesture? {
        guard kind == .pending else { return nil }
        kind = .holding
        return onSphere ? .holdBegan : .longPressSpace(start)
    }

    /// `ring`: the data ring under a tap, if any.
    mutating func end(at point: CGPoint, ring: Int?) -> PresenceGesture? {
        defer { kind = .done }
        switch kind {
        case .pending:
            if let ring { return .tapRing(ring) }
            return onHeart || onSphere ? .tapHeart : .tapSpace
        case .holding:
            return onSphere ? .holdEnded : nil
        case .swiping:
            let dy = point.y - start.y, dx = point.x - start.x
            if abs(dx) > abs(dy) {
                guard abs(dx) > Self.swipeDistance else { return nil }
                return dx < 0 ? .swipeLeft : .swipeRight
            }
            guard abs(dy) > Self.swipeDistance else { return nil }
            return dy < 0 ? .swipeUp : .swipeDown
        case .spinning, .done:
            return nil
        }
    }
}

/// What the data rings show.
enum PresenceRings {
    static let requestsRing = 0
    static let messagesRing = 1
    static let resultsRing = 2
    static let tasksRing = 3

    static func states(unread: Int, requests: Int, hasResults: Bool, focused: Int? = nil,
                       task: TaskUpdate? = nil) -> [PresenceRingState] {
        var rings = Array(repeating: PresenceRingState(), count: PresenceGeometry.rings.count)
        if let task { rings[tasksRing] = taskRing(task) }
        rings[requestsRing] = PresenceRingState(kind: .requests, lit: min(requests * 5, PresenceGeometry.rings[requestsRing].blocks))
        rings[messagesRing] = PresenceRingState(kind: .messages, lit: min(unread * 4, PresenceGeometry.rings[messagesRing].blocks))
        rings[resultsRing] = PresenceRingState(kind: .results, lit: hasResults ? 10 : 0)
        if let focused, rings.indices.contains(focused) { rings[focused].focused = true }
        return rings
    }

    /// The tasks ring fills block by block: by the known total, else a little per step; full when done.
    static func taskRing(_ task: TaskUpdate) -> PresenceRingState {
        let blocks = PresenceGeometry.rings[tasksRing].blocks
        let lit: Int
        if task.state != .running {
            lit = blocks
        } else if let fraction = task.contentState().fraction {
            lit = max(1, Int((fraction * Double(blocks)).rounded()))
        } else {
            lit = min(blocks - 10, max(1, task.step) * 10)
        }
        return PresenceRingState(kind: .tasks, lit: lit, active: task.state == .running)
    }

    /// VoiceOver: what a ring holds, or nil when quiet.
    static func summary(_ ring: PresenceRingState) -> String? {
        guard ring.lit > 0 else { return nil }
        switch ring.kind {
        case .messages: return "Unread messages"
        case .requests: return "Waiting for your decision"
        case .results: return "Results to show"
        case .tasks: return ring.active ? "Working" : "Task finished"
        case .plain: return nil
        }
    }
}
