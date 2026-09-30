import HermesCallCore
import ImageIO
import os
import UniformTypeIdentifiers
import WidgetKit

/// Renders the real (Metal) presence as a still per agent colour into the app group, so widgets and
/// the Live Activity show the same sphere as the app (WidgetKit cannot run Metal itself).
@MainActor
enum PresenceStill {
    static let pixels = 360
    /// Rendered at the app's own size (points at 3×), then scaled down, so filaments and motes keep the app's proportions.
    static let renderPixels = 1260

    static func refresh(_ palette: AgentPalette) {
        let url = SharedContainer.presenceStillURL(palette)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let engine = PresenceEngine()
        engine.palette = palette
        engine.snapPalette()
        engine.settle()
        engine.roomLight = false
        // Points at 3× like the app on an iPhone, so lines and motes have the app's proportions.
        let side = Double(renderPixels) / 3
        engine.place(center: CGPoint(x: side / 2, y: side / 2), radius: side / 2 * 0.62, animated: false)
        // The three-quarter view the app shows most of the time (rings open, not edge-on).
        engine.drag(by: CGSize(width: 0.9 * side * 0.62 / 1.6, height: -0.25 * side * 0.62 / 1.6), scale: side / 2 * 0.62)
        guard let renderer = PresenceRenderer(engine: engine), let large = renderer.snapshot(pixels: renderPixels, scale: 3),
              let image = downscaled(large),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            Logger(subsystem: "de.quavon.hermescall", category: "presence").error("presence still not rendered")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { WidgetCenter.shared.reloadAllTimelines() }
    }

    private static func downscaled(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }

    #if DEBUG
    /// `-RenderIcons YES`: app icon candidates from the real presence (Documents/icons), for tools/render_icons.swift.
    static func renderIconCandidatesIfRequested() {
        guard UserDefaults.standard.bool(forKey: "RenderIcons") else { return }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("icons")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // name, sphere radius (share of half the side), yaw/pitch drag, call energy
        // name, sphere radius (share of half the side), yaw/pitch drag, render scale (lower = bolder lines)
        let variants: [(String, Double, Double, Double, Double)] = [
            ("m", 0.62, 2.1, 0.35, 4), ("n", 0.62, 3.0, -0.15, 4), ("o", 0.64, 2.4, 0.0, 5),
            ("p", 0.60, 2.1, 0.35, 5), ("q", 0.66, 3.0, -0.3, 4.5), ("r", 0.62, 1.2, -0.2, 4),
        ]
        let render = 2048
        for (name, share, yaw, pitch, scale) in variants {
            let side = Double(render) / scale
            let engine = PresenceEngine()
            engine.palette = .gold
            engine.snapPalette()
            engine.settle()
            engine.energize()
            let radius = side / 2 * share
            engine.place(center: CGPoint(x: side / 2, y: side / 2), radius: radius, animated: false)
            engine.drag(by: CGSize(width: yaw * radius / 1.6, height: pitch * radius / 1.6), scale: radius)
            guard let renderer = PresenceRenderer(engine: engine),
                  let image = renderer.snapshot(pixels: render, scale: scale, transparent: false),
                  let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("presence-\(name).png") as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        Logger(subsystem: "de.quavon.hermescall", category: "presence").info("icon candidates rendered")
    }
    #endif
}
