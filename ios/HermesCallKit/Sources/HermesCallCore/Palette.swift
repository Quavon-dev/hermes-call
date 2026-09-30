import Foundation

/// Each paired agent can have its own colour (the presence, the HUD, widgets). Gold is the default.
public enum AgentPalette: String, Codable, Sendable, CaseIterable, Identifiable {
    case gold, ice, violet, emerald, crimson

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// sRGB components 0…1.
    public struct RGB: Sendable, Hashable {
        public let r: Float, g: Float, b: Float
        public init(_ r: Float, _ g: Float, _ b: Float) { (self.r, self.g, self.b) = (r, g, b) }
    }

    /// The presence's main light (blocks, filaments).
    public var glow: RGB {
        switch self {
        case .gold: RGB(1.0, 0.65, 0.16)  // #FFA629
        case .ice: RGB(0.36, 0.78, 1.0)
        case .violet: RGB(0.69, 0.49, 1.0)
        case .emerald: RGB(0.24, 0.86, 0.59)
        case .crimson: RGB(1.0, 0.3, 0.37)
        }
    }

    /// The hot white-tinted highlight (the heart, speaking waves).
    public var light: RGB {
        switch self {
        case .gold: RGB(1.0, 0.91, 0.69)  // #FFE9B0
        case .ice: RGB(0.84, 0.95, 1.0)
        case .violet: RGB(0.92, 0.87, 1.0)
        case .emerald: RGB(0.82, 0.98, 0.9)
        case .crimson: RGB(1.0, 0.84, 0.85)
        }
    }

    /// Deep accent (requests, the far side of the rings).
    public var alert: RGB {
        switch self {
        case .gold: RGB(0.88, 0.38, 0.05)  // #E0620E
        case .ice: RGB(0.12, 0.44, 0.88)
        case .violet: RGB(0.48, 0.18, 0.88)
        case .emerald: RGB(0.05, 0.62, 0.35)
        case .crimson: RGB(0.78, 0.06, 0.18)
        }
    }

    /// The darkest tone (back of the orrery, the room's light).
    public var ember: RGB {
        switch self {
        case .gold: RGB(0.42, 0.16, 0.02)  // #6B2A05
        case .ice: RGB(0.04, 0.16, 0.31)
        case .violet: RGB(0.18, 0.04, 0.33)
        case .emerald: RGB(0.02, 0.23, 0.13)
        case .crimson: RGB(0.29, 0.02, 0.06)
        }
    }

    /// The first colour not used by `taken` (new pairings get a different colour than existing agents).
    public static func next(after taken: [AgentPalette]) -> AgentPalette {
        allCases.first { !taken.contains($0) } ?? .gold
    }
}

extension RelayProfile {
    /// Older profiles have no colour: gold.
    public var agentPalette: AgentPalette { palette ?? .gold }
}

extension SharedContainer {
    /// The active agent's colour, so widgets and the Live Activity match the app.
    public static let paletteKey = "palette"
    /// The active agent's display name (Live Activity, widgets).
    public static let agentNameKey = "agentName"

    /// A still of the app's presence in this colour (rendered by the app), for widgets and the Live Activity.
    public static func presenceStillURL(_ palette: AgentPalette) -> URL {
        directory.appendingPathComponent("presence-v5-\(palette.rawValue).png")
    }

    public static var agentName: String {
        defaults.string(forKey: agentNameKey) ?? RelayProfile.defaultAgentName
    }

    public static var palette: AgentPalette {
        defaults.string(forKey: paletteKey).flatMap(AgentPalette.init(rawValue:)) ?? .gold
    }
}
