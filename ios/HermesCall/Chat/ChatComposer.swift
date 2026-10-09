import HermesCallCore
import PhotosUI
import SwiftUI
import UIKit

/// Text field, attachments (photos, camera, files) and voice notes.
struct ChatComposer: View {
    let hud: Bool
    var composing: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    @Environment(CallCoordinator.self) private var calls
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var choosingPhotos = false
    @State private var capturing = false
    @State private var micDenied = false
    @State private var recorder = VoiceRecorder()
    @State private var sent = 0

    static let maxFiles = 4

    private var suggestions: [SlashCommand] { recorder.isRecording ? [] : SlashCommand.suggestions(for: draft) }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                if !suggestions.isEmpty {
                    SlashSuggestions(commands: suggestions, hud: hud, pick: pick)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if recorder.isRecording {
                        recordingBar.transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if hud {
                        attachMenu
                        field
                        actionButton
                    } else {
                        // Standard: a glass "+" beside a glass field that holds its own mic / send button.
                        attachMenu
                        HStack(alignment: .bottom, spacing: 6) {
                            field
                            actionButton.padding(.bottom, 5)
                        }
                        .padding(.trailing, 5)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Metrics.controlHeight / 2 + 1))
                    }
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: suggestions.map(\.name))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: recorder.isRecording)
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background { if hud { Color.black.ignoresSafeArea(edges: .bottom) } }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: Self.maxFiles, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPhotos(items) }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { sendFiles(urls) }
        }
        .fullScreenCover(isPresented: $capturing) {
            CameraPicker { image in Task { await sendCameraPhoto(image) } }.ignoresSafeArea()
        }
        .alert("Microphone access is off", isPresented: $micDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voice notes need the microphone. Allow it for Hermes Call in Settings.")
        }
    }

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var actionButton: some View {
        Button {
            if isEmpty { Task { await startRecording() } } else { sendDraft() }
        } label: {
            if hud {
                ComposerIcon(symbol: isEmpty ? "mic.fill" : "arrow.up", hud: hud)
                    .symbolEffect(.bounce, value: sent)
            } else {
                ComposerIcon(symbol: isEmpty ? "mic.fill" : "arrow.up", size: Self.inlineButton, quiet: isEmpty)
                    .symbolEffect(.bounce, value: sent)
            }
        }
        .disabled(isEmpty && calls.inCall)
        .animation(.snappy(duration: 0.2), value: isEmpty)
        .accessibilityLabel(isEmpty ? "Record a voice note" : "Send")
    }

    private func pick(_ command: SlashCommand) {
        if !command.runsAtOnce {
            draft = command.text + " "
            return
        }
        draft = ""
        sent += 1
        chat.run(command, calls: calls)
    }

    private var attachMenu: some View {
        Menu {
            Section("Commands") {
                ForEach([SlashCommand.new, .retry, .undo]) { command in
                    Button { chat.run(command, calls: calls) } label: { Label(command.summary, systemImage: command.symbol) }
                }
            }
            Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { capturing = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { importingFiles = true } label: { Label("Files", systemImage: "doc") }
        } label: {
            if hud {
                ComposerIcon(symbol: "plus", hud: hud)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .accessibilityLabel("Attach")
    }

    private var field: some View {
        TextField("Message", text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .focused(composing)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: Metrics.controlHeight)
            .padding(.leading, hud ? 0 : 4)
            .background {
                if hud {
                    RoundedRectangle(cornerRadius: Metrics.controlHeight / 2).stroke(HUD.glow.opacity(0.35), lineWidth: 0.75)
                }
            }
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) { _ = recorder.stop(keep: false) } label: {
                ComposerIcon(symbol: "trash.fill", hud: hud, tint: .red, size: hud ? Metrics.iconButton : Self.inlineButton)
            }
            .accessibilityLabel("Discard voice note")
            Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
            WaveformBars(bars: recorder.levels.count < VoiceRecorder.liveBars
                ? Array(repeating: 0.04, count: VoiceRecorder.liveBars - recorder.levels.count) + recorder.levels
                : recorder.levels, progress: 1)
                .frame(height: 26)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Button {
                if let note = recorder.stop(keep: true) { Task { await chat.send(text: "", files: [note]) } }
            } label: {
                ComposerIcon(symbol: "arrow.up", hud: hud, size: hud ? Metrics.iconButton : Self.inlineButton)
            }
            .accessibilityLabel("Send voice note")
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.controlHeight)
        .padding(.horizontal, hud ? 0 : 5)
        .glassEffect(hud ? .identity : .regular, in: .capsule)
    }

    /// The send / mic button inside the Standard appearance's glass field.
    private static let inlineButton: CGFloat = 34

    private func startRecording() async {
        switch await recorder.start() {
        case .recording: break
        case .denied: micDenied = true
        case .failed: app.lastError = "Recording could not start. Is another app using the microphone?"
        }
    }

    private func takeCaption() -> String {
        let caption = draft
        draft = ""
        return caption
    }

    private func sendDraft() {
        let text = takeCaption()
        sent += 1
        Task { await chat.send(text: text) }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var files: [OutgoingFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = PhotoEncoder.jpeg(data) else { continue }
            files.append(OutgoingFile(kind: .photo, name: "Photo \(index + 1).jpg", mime: "image/jpeg", data: jpeg))
        }
        if files.count < items.count { app.lastError = "\(items.count - files.count) of the photos could not be read." }
        guard !files.isEmpty else { return }
        await chat.send(text: takeCaption(), files: files)
    }

    private func sendCameraPhoto(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.95), let jpeg = PhotoEncoder.jpeg(data) else { return }
        await chat.send(text: takeCaption(), files: [OutgoingFile(kind: .photo, name: "Photo.jpg", mime: "image/jpeg", data: jpeg)])
    }

    /// Up to four files per message; what does not fit or is too large is named.
    private func sendFiles(_ urls: [URL]) {
        var files: [OutgoingFile] = []
        var tooLarge: [String] = []
        for url in urls.prefix(Self.maxFiles) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let file = try? OutgoingFile.from(url: url) { files.append(file) } else { tooLarge.append(url.lastPathComponent) }
        }
        var problems: [String] = []
        if urls.count > Self.maxFiles { problems.append("Up to \(Self.maxFiles) files per message: \(urls.count - Self.maxFiles) were left out.") }
        if !tooLarge.isEmpty { problems.append("Too large (at most 10 MB) or unreadable: \(tooLarge.joined(separator: ", ")).") }
        if !problems.isEmpty { app.lastError = problems.joined(separator: " ") }
        guard !files.isEmpty else { return }
        let caption = takeCaption()
        Task { await chat.send(text: caption, files: files) }
    }
}

/// Round composer button exactly as tall as the single-line field (and the round header buttons), its
/// symbol centred: a filled circle in the tint, the symbol in the background colour.
struct ComposerIcon: View {
    let symbol: String
    var hud = false
    var tint: Color?
    var size = Metrics.iconButton
    /// Just the symbol, no filled circle (the mic inside the glass field).
    var quiet = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: size * (quiet ? 0.5 : 0.42), weight: .semibold))
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : hud ? AnyShapeStyle(HUD.deep) : AnyShapeStyle(.white))
            .frame(width: size, height: size)
            .background {
                if !quiet {
                    Circle().fill(tint.map(AnyShapeStyle.init) ?? (hud ? AnyShapeStyle(HUD.glow) : AnyShapeStyle(.tint)))
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
    }
}

/// The system camera for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let taken: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.taken(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
