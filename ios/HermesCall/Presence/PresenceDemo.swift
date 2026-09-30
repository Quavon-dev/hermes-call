#if DEBUG
import Foundation

/// Simulator stand-in for a call (CallKit calls end at once there). Launch with `-PresenceDemo YES`
/// (HUD appearance) so tapping the presence starts a fake call; `-PresenceDemoAuto YES` starts one.
/// Levels cycle listening → thinking → speaking, with captions.
@MainActor @Observable
final class PresenceDemo {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "PresenceDemo") }
    static var autoStart: Bool { UserDefaults.standard.bool(forKey: "PresenceDemoAuto") }

    private(set) var since: Date?
    private(set) var captions: [CallCoordinator.Caption] = []
    private var shownCycle = -1
    var active: Bool { since != nil }

    private static let lines = [
        (false, "Find me a quiet place for dinner nearby."),
        (true, "Three places are open near you. The trattoria has a table at eight."),
        (false, "Book the trattoria."),
        (true, "Done. I added it to your calendar and sent you the route."),
    ]

    func start() {
        since = Date()
        captions = []
        shownCycle = -1
    }

    func end() {
        since = nil
        captions = []
    }

    /// (agent, mic) for this moment of the 12-second cycle; adds the matching caption.
    func sample(now: Date = Date()) -> (agent: Double, mic: Double) {
        guard let since else { return (0, 0) }
        let elapsed = now.timeIntervalSince(since)
        let phase = elapsed.truncatingRemainder(dividingBy: 12)
        let wobble = abs(sin(now.timeIntervalSinceReferenceDate * 7))
        let cycle = Int(elapsed / 6)
        if cycle != shownCycle {
            shownCycle = cycle
            let line = Self.lines[cycle % Self.lines.count]
            captions = Array((captions + [CallCoordinator.Caption(fromAgent: line.0, text: line.1, date: now)]).suffix(2))
        }
        switch phase {
        case ..<1.5: return (0, 0)
        case ..<4.5: return (0, 0.12 * wobble)
        case ..<6.5: return (0, 0)
        default: return (0.22 * wobble, 0)
        }
    }
}
#endif
