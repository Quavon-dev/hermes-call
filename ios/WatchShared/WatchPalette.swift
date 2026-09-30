import SwiftUI

/// The agent's colours on the watch (same values as `AgentPalette` on the iPhone).
struct WatchPalette: Equatable {
    let glow: Color
    let light: Color
    let ember: Color

    init(_ name: String) {
        switch name {
        case "ice": self.init(glow: (0.36, 0.78, 1.0), light: (0.84, 0.95, 1.0), ember: (0.04, 0.16, 0.31))
        case "violet": self.init(glow: (0.69, 0.49, 1.0), light: (0.92, 0.87, 1.0), ember: (0.18, 0.04, 0.33))
        case "emerald": self.init(glow: (0.24, 0.86, 0.59), light: (0.82, 0.98, 0.9), ember: (0.02, 0.23, 0.13))
        case "crimson": self.init(glow: (1.0, 0.3, 0.37), light: (1.0, 0.84, 0.85), ember: (0.29, 0.02, 0.06))
        default: self.init(glow: (1.0, 0.65, 0.16), light: (1.0, 0.91, 0.69), ember: (0.42, 0.16, 0.02))
        }
    }

    private init(glow: (Double, Double, Double), light: (Double, Double, Double), ember: (Double, Double, Double)) {
        self.glow = Color(red: glow.0, green: glow.1, blue: glow.2)
        self.light = Color(red: light.0, green: light.1, blue: light.2)
        self.ember = Color(red: ember.0, green: ember.1, blue: ember.2)
    }

    /// The complication reads the agent's name and colour from the watch app group.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "HermesCallAppGroup") as? String
        ?? "group.de.quavon.hermescall"

    static func share(_ snapshot: WatchSnapshot) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(snapshot.palette, forKey: "palette")
        defaults?.set(snapshot.agentName, forKey: "agentName")
    }

    static var shared: (palette: WatchPalette, name: String) {
        let defaults = UserDefaults(suiteName: appGroup)
        return (WatchPalette(defaults?.string(forKey: "palette") ?? "gold"), defaults?.string(forKey: "agentName") ?? "Hermes")
    }
}
