import HermesCallCore
import SwiftUI
import WidgetKit

enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case standard, hud
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "HUD" }
}

/// Shared layout sizes, so controls line up across screens and appearances.
enum Metrics {
    /// Height of single-line controls: text fields, pills, segmented rows (also the minimum hit target).
    static let controlHeight: CGFloat = 44
    /// Icon-only buttons next to a field (attach, mic, send): square hit area.
    static let iconButton: CGFloat = 44
    /// Symbol size inside `iconButton`.
    static let iconSize: CGFloat = 28
    /// Round call controls (mute, speaker, end): one size, so the captions share a baseline.
    static let callButton: CGFloat = 68
    static let cornerRadius: CGFloat = 18
}

/// The active agent's colour (each paired agent has its own; gold by default). Views that read
/// `HUD.glow` etc. are redrawn when it changes (Observation tracks the read).
@MainActor @Observable
final class HUDTheme {
    static let shared = HUDTheme()
    private(set) var palette = SharedContainer.palette

    func apply(_ palette: AgentPalette) {
        guard palette != self.palette || SharedContainer.palette != palette else { return }
        self.palette = palette
        SharedContainer.defaults.set(palette.rawValue, forKey: SharedContainer.paletteKey)
        PresenceStill.refresh(palette)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension Color {
    init(_ rgb: AgentPalette.RGB) { self.init(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b)) }
}

/// The HUD appearance: the agent's light (gold by default) in a black room. The presence (Presence/)
/// carries the look; everything else stays quiet — hairline type, near-black surfaces, no decoration.
@MainActor
enum HUD {
    static var glow: Color { Color(HUDTheme.shared.palette.glow) }
    static var light: Color { Color(HUDTheme.shared.palette.light) }
    static var alert: Color { Color(HUDTheme.shared.palette.alert) }
    static var ember: Color { Color(HUDTheme.shared.palette.ember) }
    static let deep = Color(red: 0.03, green: 0.024, blue: 0.02)  // #080605

    /// Small spaced capitals, the only "HUD" typography left.
    static func label(_ text: String, size: CGFloat = 10) -> some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(size * 0.25)
            .foregroundStyle(glow.opacity(0.85))
    }
}

extension View {
    /// Applies the HUD look app-wide (dark scheme, gold tint, monospaced type) when `on`.
    @ViewBuilder func hudStyle(_ on: Bool) -> some View {
        if on {
            preferredColorScheme(.dark).tint(HUD.glow).fontDesign(.monospaced)
        } else {
            // Standard appearance: the agent's colour as the tint, in its deeper tone (readable on white).
            tint(HUD.alert)
        }
    }

    /// A quiet near-black surface with a hairline edge (cards, bubbles, fields in HUD appearance).
    func hudSurface(tint: Color = HUD.glow, fill: Double = 0.06, cornerRadius: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(0.55)))
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(tint.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(tint.opacity(0.28), lineWidth: 0.75))
    }
}
