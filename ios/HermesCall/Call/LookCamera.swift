import AVFoundation
import CoreImage
import os
import PhotosUI
import SwiftUI
import UIKit

/// The back camera for "look at this": keeps the newest frame, so a shutter tap or the live mode
/// (one frame every few seconds) can hand it to the agent as a still.
final class LookCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "de.quavon.hermescall.look")
    private let lock = OSAllocatedUnfairLock()
    private var latest: CIImage?  // guarded by `lock`
    private let context = CIContext()
    private var configured = false

    /// Longest side of a frame sent to the agent.
    static let maxPixels: CGFloat = 1280

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.withLock { latest = nil }
        }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        // The call owns the audio session; the camera must not touch it.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        output.connection(with: .video)?.videoRotationAngle = 90  // portrait
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        lock.withLock { latest = image }
    }

    /// The newest frame as JPEG (≤ 1280 px, no metadata), or nil before the first frame.
    func snapshot() -> Data? {
        guard let image = lock.withLock({ latest }) else { return nil }
        let scale = min(1, Self.maxPixels / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: scaled, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72])
    }

    /// A picked photo, re-encoded like a camera frame (≤ 1280 px JPEG without metadata).
    static func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixels / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.72)
    }
}

/// The live camera picture.
struct LookPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// "Look at this" during a call: point the camera at something (or pick a photo) and ask about it.
/// Shutter sends one still; Live sends one every few seconds while the sheet is open.
struct LookSheet: View {
    @Environment(CallCoordinator.self) private var calls
    @Environment(\.dismiss) private var dismiss
    /// Called for every sent frame (the presence absorbs it).
    var onSent: () -> Void = {}

    @State private var camera = LookCamera()
    @State private var allowed: Bool?
    @State private var live = false
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var sentCount = 0
    @State private var flash = false

    static let liveInterval: Duration = .seconds(3)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if allowed == true {
                LookPreview(session: camera.session).ignoresSafeArea()
                Color.white.opacity(flash ? 0.35 : 0).ignoresSafeArea().allowsHitTesting(false)
            } else if allowed == false {
                VStack(spacing: 12) {
                    Text("Camera access is off.").foregroundStyle(HUD.light)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("You can still show a photo from your library.").font(.footnote).foregroundStyle(HUD.glow.opacity(0.7))
                }
                .padding(32)
            }
            VStack {
                HStack {
                    HUD.label(live ? "live · every 3 s" : "look", size: 9)
                    Spacer()
                    if sentCount > 0 { HUD.label("\(sentCount) sent", size: 9).opacity(0.7) }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.light)
                            .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                Spacer()
                controls.padding(.bottom, 24)
            }
        }
        .hudStyle(true)
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: 1, matching: .images)
        .onChange(of: picked) { _, items in
            guard let item = items.first else { return }
            picked = []
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = LookCamera.jpeg(from: data) {
                    await send(jpeg)
                }
            }
        }
        .task {
            allowed = await LookCamera.authorize()
            if allowed == true { camera.start() }
        }
        .task(id: live) {
            while live, !Task.isCancelled {
                if let frame = camera.snapshot() { await send(frame) }
                try? await Task.sleep(for: Self.liveInterval)
            }
        }
        .onDisappear { camera.stop() }
        .onChange(of: calls.inCall) { _, inCall in if !inCall { dismiss() } }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            Button { picking = true } label: {
                Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(HUD.light)
                    .frame(width: 52, height: 52).background(Circle().fill(Color.black.opacity(0.5)))
            }
            .accessibilityLabel("Show a photo from the library")
            Button {
                Task { if let frame = camera.snapshot() { await send(frame) } }
            } label: {
                Circle().stroke(HUD.light, lineWidth: 3).frame(width: 72, height: 72)
                    .overlay(Circle().fill(HUD.glow.opacity(0.85)).padding(7))
            }
            .disabled(allowed != true)
            .accessibilityLabel("Show this to the agent")
            Button { live.toggle() } label: {
                Image(systemName: live ? "livephoto" : "livephoto.slash").font(.system(size: 20))
                    .foregroundStyle(live ? HUD.glow : HUD.light)
                    .frame(width: 52, height: 52).background(Circle().fill(Color.black.opacity(0.5)))
            }
            .disabled(allowed != true)
            .accessibilityLabel(live ? "Stop live view" : "Live: a picture every 3 seconds")
        }
    }

    private func send(_ jpeg: Data) async {
        guard await calls.showImage(jpeg) else { return }
        sentCount += 1
        onSent()
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.easeIn(duration: 0.3)) { flash = false }
    }
}
