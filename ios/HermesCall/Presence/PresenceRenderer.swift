import MetalKit
import os
import SwiftUI

/// Full-screen Metal view of the presence (black room, sphere, bloom). Touches pass through to
/// the SwiftUI gesture layer above it.
struct PresenceCanvas: UIViewRepresentable {
    let engine: PresenceEngine

    func makeCoordinator() -> PresenceRenderer? { PresenceRenderer(engine: engine) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = engine.reduceMotion ? 30 : 120
        view.delegate = context.coordinator
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = engine.reduceMotion ? 30 : 120
    }
}

/// Draws one frame: scene (additive, HDR) → bloom chain → composite with the room light.
@MainActor
final class PresenceRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let engine: PresenceEngine
    private let queue: MTLCommandQueue
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "presence")

    private let edgePipeline, blockPipeline, nodePipeline, motePipeline, corePipeline: MTLRenderPipelineState
    private let downsamplePipeline, upsamplePipeline, compositePipeline: MTLRenderPipelineState
    private let edges, tracks, blocks, rings, nodes: MTLBuffer
    private let edgeCount, trackCount, blockCount, nodeCount: Int

    private var scene: MTLTexture?
    private var chain: [MTLTexture] = []

    static let bloomLevels = 5
    static let moteCount = 1800
    static let hdrFormat = MTLPixelFormat.rgba16Float

    init?(engine: PresenceEngine) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        // Presence.metal is compiled at build time (Xcode's Metal toolchain component).
        guard let library = device.makeDefaultLibrary() else {
            Logger(subsystem: "de.quavon.hermescall", category: "presence").error("presence shaders missing from the app bundle")
            return nil
        }
        self.device = device
        self.engine = engine
        self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = Self.hdrFormat,
                      additive: Bool = true) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = format
            if additive {
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let edge = pipeline("edgeVertex", "lineFragment"), let block = pipeline("blockVertex", "flatFragment"),
              let node = pipeline("nodeVertex", "pointFragment"), let mote = pipeline("moteVertex", "pointFragment"),
              let core = pipeline("coreVertex", "coreFragment"),
              let down = pipeline("fullscreenVertex", "downsampleFragment", additive: false),
              let up = pipeline("fullscreenVertex", "upsampleFragment"),
              let composite = pipeline("fullscreenVertex", "compositeFragment", format: .bgra8Unorm, additive: false)
        else { return nil }
        (edgePipeline, blockPipeline, nodePipeline, motePipeline, corePipeline) = (edge, block, node, mote, core)
        (downsamplePipeline, upsamplePipeline, compositePipeline) = (down, up, composite)

        func buffer(_ values: [SIMD4<Float>]) -> MTLBuffer? {
            device.makeBuffer(bytes: values, length: max(16, values.count * MemoryLayout<SIMD4<Float>>.stride))
        }
        let edgeData = PresenceGeometry.edgeInstances(), trackData = PresenceGeometry.trackInstances()
        let blockData = PresenceGeometry.blockInstances(), nodeData = PresenceGeometry.nodeInstances()
        guard let edges = buffer(edgeData), let tracks = buffer(trackData), let blocks = buffer(blockData),
              let rings = buffer(PresenceGeometry.ringInstances()), let nodes = buffer(nodeData) else { return nil }
        (self.edges, self.tracks, self.blocks, self.rings, self.nodes) = (edges, tracks, blocks, rings, nodes)
        (edgeCount, trackCount, blockCount, nodeCount) = (edgeData.count / 2, trackData.count / 2, blockData.count / 2, nodeData.count)
        super.init()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { makeTargets(size) }
    }

    private func makeTargets(_ size: CGSize) {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: max(1, w), height: max(1, h),
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        scene = texture(width, height)
        chain = (1...Self.bloomLevels).compactMap { level in texture(width >> level, height >> level) }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        let size = view.drawableSize
        guard let drawable = view.currentDrawable, let finalPass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(), encode(commands, size: size, scale: view.contentScaleFactor, into: finalPass)
        else { return }
        commands.present(drawable)
        commands.commit()
    }

    /// One frame into an offscreen image (widgets and the Live Activity show the real presence as a still).
    /// Black becomes transparent: alpha follows brightness, so the glow sits on any dark background.
    func snapshot(pixels: Int, scale: CGFloat, transparent: Bool = true) -> CGImage? {
        let size = CGSize(width: pixels, height: pixels)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard encode(commands, size: size, scale: scale, into: pass) else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        target.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let half = Double(pixels) / 2
        for y in 0..<(transparent ? pixels : 0) {
            for x in 0..<pixels {
                let index = (y * pixels + x) * 4
                // Fade to nothing towards the edge, so no square shows on any background.
                let d = hypot(Double(x) + 0.5 - half, Double(y) + 0.5 - half) / half
                let mask = max(0, min(1, (1 - d) / 0.25))
                for channel in 0..<3 { bytes[index + channel] = UInt8(Double(bytes[index + channel]) * mask) }
                // BGRA, premultiplied: brightness becomes coverage.
                bytes[index + 3] = max(bytes[index], bytes[index + 1], bytes[index + 2])
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: (transparent ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Scene → bloom → composite into `finalPass`; false when targets are missing.
    private func encode(_ commands: MTLCommandBuffer, size: CGSize, scale: CGFloat, into finalPass: MTLRenderPassDescriptor) -> Bool {
        if scene == nil || scene?.width != Int(size.width) || scene?.height != Int(size.height) { makeTargets(size) }
        guard let scene, chain.count == Self.bloomLevels else { return false }
        var uniforms = engine.step(drawable: size, scale: scale)
        let uniformLength = uniforms.count * MemoryLayout<SIMD4<Float>>.stride

        // 1. Scene: everything additive into the HDR target.
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass(scene, clear: true)) {
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 1)
            var mode: Float = 1
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setVertexBuffer(tracks, offset: 0, index: 0)
            encoder.setVertexBytes(&mode, length: 4, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: trackCount)
            mode = 0
            encoder.setVertexBuffer(edges, offset: 0, index: 0)
            encoder.setVertexBytes(&mode, length: 4, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: edgeCount)
            encoder.setRenderPipelineState(blockPipeline)
            encoder.setVertexBuffer(blocks, offset: 0, index: 0)
            encoder.setVertexBuffer(rings, offset: 0, index: 3)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: blockCount)
            encoder.setRenderPipelineState(nodePipeline)
            encoder.setVertexBuffer(nodes, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: nodeCount)
            encoder.setRenderPipelineState(motePipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: engine.reduceMotion ? Self.moteCount / 4 : Self.moteCount)
            encoder.setRenderPipelineState(corePipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // 2. Bloom: bright parts down a half-resolution chain, then back up (additive tent).
        var source: MTLTexture = scene
        for (level, target) in chain.enumerated() {
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass(target, clear: true)) else { continue }
            var threshold: Float = level == 0 ? 0.28 : 0
            encoder.setRenderPipelineState(downsamplePipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&threshold, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            source = target
        }
        for level in stride(from: chain.count - 1, to: 0, by: -1) {
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass(chain[level - 1], clear: false)) else { continue }
            encoder.setRenderPipelineState(upsamplePipeline)
            encoder.setFragmentTexture(chain[level], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // 3. Composite onto black with the room's warm light, tone-mapped.
        if let encoder = commands.makeRenderCommandEncoder(descriptor: finalPass) {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.setFragmentTexture(chain[0], index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        return true
    }

    private func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
}
