// SPDX-License-Identifier: MIT
import Foundation

/// WCAG 2 contrast arithmetic on sRGB colours.
public enum Contrast {
    public static func luminance(_ color: AgentPalette.RGB) -> Double {
        func channel(_ value: Float) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    public static func ratio(_ a: AgentPalette.RGB, _ b: AgentPalette.RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` at `opacity` drawn over `bottom`.
    public static func blend(_ top: AgentPalette.RGB, opacity: Float, over bottom: AgentPalette.RGB) -> AgentPalette.RGB {
        AgentPalette.RGB(top.r * opacity + bottom.r * (1 - opacity), top.g * opacity + bottom.g * (1 - opacity),
                         top.b * opacity + bottom.b * (1 - opacity))
    }
}

/// How the owner's bubble draws its quieter parts in white.
public enum OwnerBubble {
    /// Transcript, time, file size.
    public static let secondaryOpacity: Float = 0.85
    /// Waveform bars not played yet.
    public static let unplayedOpacity: Float = 0.6
    /// White text on the bubble needs at least this, so the softer parts still pass AA.
    static let targetRatio = 7.0
}

extension AgentPalette {
    /// The owner's bubble in the Standard appearance: the agent's accent, darkened until white text on it
    /// (and the softer transcript and waveform) passes WCAG AA.
    public var ownerBubble: RGB {
        var scale: Float = 1
        var color = alert
        while Contrast.ratio(RGB(1, 1, 1), color) < OwnerBubble.targetRatio, scale > 0.2 {
            scale -= 0.05
            color = RGB(alert.r * scale, alert.g * scale, alert.b * scale)
        }
        return color
    }
}
