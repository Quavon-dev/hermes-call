import Foundation

/// A simulated call: voice levels cycle listening → thinking → speaking, with captions. The demo agent's
/// calls use it (DemoAgent), and so does the Simulator, where CallKit ends every real call at once:
/// debug builds launched with `-PresenceDemo YES` make every call a simulated one; `-PresenceDemoAuto YES`
/// starts one by itself (HUD appearance).
@MainActor @Observable
final class PresenceDemo {
    #if DEBUG
    static var forced: Bool { UserDefaults.standard.bool(forKey: "PresenceDemo") }
    static var autoStart: Bool { UserDefaults.standard.bool(forKey: "PresenceDemoAuto") }
    /// `-PresenceDemoReconnect YES`: the simulated call shows "Reconnecting…" (screenshots of C1).
    static var showsReconnect: Bool { UserDefaults.standard.bool(forKey: "PresenceDemoReconnect") }
    #else
    static let forced = false
    static let autoStart = false
    static let showsReconnect = false
    #endif

    /// The simulated call pretends its connection is being moved (see `showsReconnect`).
    let reconnecting = PresenceDemo.showsReconnect

    private(set) var since: Date?
    private(set) var captions: [CallCoordinator.Caption] = []
    private var shownCycle = -1
    private let lines: [(fromAgent: Bool, text: String)]
    var active: Bool { since != nil }

    static let defaultLines: [(fromAgent: Bool, text: String)] = [
        (false, "Find me a quiet place for dinner nearby."),
        (true, "Three places are open near you. The trattoria has a table at eight."),
        (false, "Book the trattoria."),
        (true, "Done. I added it to your calendar and sent you the route."),
    ]

    init(lines: [(fromAgent: Bool, text: String)] = PresenceDemo.defaultLines) {
        self.lines = lines.isEmpty ? Self.defaultLines : lines
    }

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
            let line = lines[cycle % lines.count]
            captions = Array((captions + [CallCoordinator.Caption(fromAgent: line.fromAgent, text: line.text, date: now)]).suffix(2))
        }
        switch phase {
        case ..<1.5: return (0, 0)
        case ..<4.5: return (0, 0.12 * wobble)
        case ..<6.5: return (0, 0)
        default: return (0.22 * wobble, 0)
        }
    }
}
