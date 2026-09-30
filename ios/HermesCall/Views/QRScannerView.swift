@preconcurrency import AVFoundation
import SwiftUI

/// The scanner, or why it cannot run: camera access asked for first, and when it is off an explanation
/// with a way to Settings (the code can always be typed instead).
struct QRScannerSection: View {
    let onLink: (String) -> Void
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                QRScannerView(onLink: onLink)
            case .notDetermined:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                denied
            }
        }
        .task {
            guard status == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private var denied: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Camera access is off").font(.headline)
            Text(status == .restricted
                 ? "The camera is restricted on this iPhone. Enter the code instead."
                 : "Allow the camera in Settings to scan the pairing QR code, or enter the code instead.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if status == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("scanner.denied")
    }
}

/// Minimal QR scanner that reports the first hermescall:// link it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onLink: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(onLink: onLink)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let onLink: (String) -> Void
        private var reported = false

        init(onLink: @escaping (String) -> Void) {
            self.onLink = onLink
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                let label = UILabel()
                label.text = "No camera available.\nEnter the code instead."
                label.numberOfLines = 0
                label.textAlignment = .center
                label.textColor = .white
                label.font = .preferredFont(forTextStyle: .body)
                label.adjustsFontForContentSizeCategory = true
                label.frame = view.bounds
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(label)
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.forEach { $0.frame = view.bounds }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            let value = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
                .first { $0.hasPrefix("hermescall://") }
            guard let value else { return }
            MainActor.assumeIsolated {
                guard !reported else { return }
                reported = true
                onLink(value)
            }
        }
    }
}
