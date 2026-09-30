// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

/// The owner's bubble (Standard appearance) carries white text, a softer transcript and waveform bars:
/// WCAG AA needs 4.5:1 for text and 3:1 for graphics.
struct PaletteContrastTests {
    let white = AgentPalette.RGB(1, 1, 1)

    @Test(arguments: AgentPalette.allCases)
    func ownerBubbleMeetsAA(_ palette: AgentPalette) {
        let bubble = palette.ownerBubble
        #expect(Contrast.ratio(white, bubble) >= 4.5)
        #expect(Contrast.ratio(Contrast.blend(white, opacity: OwnerBubble.secondaryOpacity, over: bubble), bubble) >= 4.5,
                "transcript, time and file sizes")
        #expect(Contrast.ratio(Contrast.blend(white, opacity: OwnerBubble.unplayedOpacity, over: bubble), bubble) >= 3,
                "unplayed waveform bars")
    }

    /// The old bubble (the plain accent tone) failed for several colours.
    @Test func plainAlertToneWasTooLight() {
        #expect(Contrast.ratio(white, AgentPalette.emerald.alert) < 4.5)
    }

    @Test func ratioOfBlackAndWhiteIsTwentyOne() {
        #expect(abs(Contrast.ratio(white, AgentPalette.RGB(0, 0, 0)) - 21) < 0.01)
    }
}
