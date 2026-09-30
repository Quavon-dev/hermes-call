import HermesCallCore
import PhotosUI
import QuickLook
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var app
    @Environment(ChatModel.self) private var chat
    @Environment(CallCoordinator.self) private var calls
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFile = false
    @State private var choosingPhotos = false
    @State private var recorder = VoiceRecorder()
    @State private var preview: URL?
    @FocusState private var composing: Bool

    private var hud: Bool { app.preferences.appearance == .hud }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                if chat.agentTyping {
                    TypingIndicator(hud: hud)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
                composer
            }
            .animation(.easeInOut(duration: 0.2), value: chat.agentTyping)
            .background { if hud { Color.black.ignoresSafeArea() } }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.bar), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .quickLookPreview($preview)
            .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await sendPhotos(items) }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { sendFile(url) }
            }
        }
        .onAppear { chat.isVisible = true }
        .onDisappear {
            chat.isVisible = false
            chat.player.stop()
        }
        .task(id: app.activeProfile?.id) { await chat.reload() }
    }

    // MARK: messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if chat.messages.isEmpty {
                        emptyState.padding(.top, 80)
                    }
                    ForEach(chat.messages) { message in
                        MessageRow(message: message, agentName: chat.agentName, hud: hud, player: chat.player,
                                   open: { attachment in Task { preview = await chat.attachmentURL(attachment) } },
                                   play: { attachment in
                                       Task {
                                           if let url = await chat.attachmentURL(attachment) { chat.player.toggle(id: attachment.id, url: url) }
                                       }
                                   },
                                   retry: { Task { await chat.retry(message) } })
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // No .defaultScrollAnchor(.bottom): with a lazy stack and the keyboard it loops layout forever.
            .onAppear { scrollToEnd(proxy, animated: false) }
            .onChange(of: chat.messages.last?.id) { scrollToEnd(proxy) }
            .onChange(of: composing) { _, focused in if focused { scrollToEnd(proxy) } }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = chat.messages.last?.id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .bottom) }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(hud ? HUD.glow : .secondary)
            Text("Chat with \(chat.agentName)").font(.headline)
            Text("Messages, photos and voice notes are end-to-end encrypted to your bridge. The history stays on this iPhone.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                if hud {
                    HUD.label(chat.agentName, size: 12).foregroundStyle(HUD.light)
                } else {
                    Text(chat.agentName).font(.headline)
                }
                Text(subtitle).font(.caption2).foregroundStyle(chat.agentTyping ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { Task { await calls.startCall() } } label: { Label("Call now", systemImage: "phone.fill") }
                    .disabled(app.relayStatus != .connected || calls.inCall)
                Button { Task { await chat.send(text: ChatModel.callMeText) } } label: {
                    Label("Ask \(chat.agentName) to call me", systemImage: "phone.arrow.down.left")
                }
            } label: {
                Label("Call", systemImage: "phone")
            } primaryAction: {
                Task { await calls.startCall() }
            }
            .disabled(calls.inCall)
        }
    }

    private var subtitle: String {
        if chat.agentTyping { return "typing…" }
        switch app.relayStatus {
        case .connected: return "end-to-end encrypted"
        case .connecting: return "connecting…"
        case .disconnected: return "offline · messages wait in the outbox"
        }
    }

    // MARK: composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if recorder.isRecording {
                recordingBar
            } else {
                Menu {
                    Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { importingFile = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    ComposerIcon(name: "plus.circle.fill")
                }
                .accessibilityLabel("Attach")
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: Metrics.controlHeight)
                    .background {
                        if hud {
                            RoundedRectangle(cornerRadius: Metrics.controlHeight / 2).stroke(HUD.glow.opacity(0.35), lineWidth: 0.75)
                        } else {
                            RoundedRectangle(cornerRadius: Metrics.controlHeight / 2).fill(.quaternary)
                        }
                    }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { Task { _ = await recorder.start() } } label: { ComposerIcon(name: "mic.circle.fill") }
                        .disabled(calls.inCall)
                        .accessibilityLabel("Record a voice note")
                } else {
                    Button(action: sendDraft) { ComposerIcon(name: "arrow.up.circle.fill") }
                        .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hud ? AnyShapeStyle(Color.black) : AnyShapeStyle(.bar))
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { _ = recorder.stop(keep: false) } label: {
                ComposerIcon(name: "trash.circle.fill")
            }
            .accessibilityLabel("Discard voice note")
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).foregroundStyle(.red)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
            Spacer()
            Button {
                if let note = recorder.stop(keep: true) { Task { await chat.send(text: "", files: [note]) } }
            } label: {
                ComposerIcon(name: "arrow.up.circle.fill")
            }
            .accessibilityLabel("Send voice note")
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.controlHeight)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await chat.send(text: text) }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var files: [OutgoingFile] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = PhotoEncoder.jpeg(data) else { continue }
            files.append(OutgoingFile(kind: .photo, name: "Photo \(index + 1).jpg", mime: "image/jpeg", data: jpeg))
        }
        let caption = draft
        draft = ""
        await chat.send(text: caption, files: files)
    }

    private func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try OutgoingFile.from(url: url)
            let caption = draft
            draft = ""
            Task { await chat.send(text: caption, files: [file]) }
        } catch {
            app.lastError = "Files can be at most 10 MB."
        }
    }
}

/// Composer symbol in a square hit area as tall as the single-line field.
private struct ComposerIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: Metrics.iconSize))
            .frame(width: Metrics.iconButton, height: Metrics.iconButton)
            .contentShape(Rectangle())
    }
}

enum PhotoEncoder {
    /// JPEG, longest side at most 2048 px: small enough for the relay, readable for vision models.
    static func jpeg(_ data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.82)
    }
}

// MARK: - Rows

struct MessageRow: View {
    let message: ChatMessage
    let agentName: String
    let hud: Bool
    let player: VoicePlayer
    let open: (ChatAttachment) -> Void
    let play: (ChatAttachment) -> Void
    let retry: () -> Void

    var body: some View {
        if let presentation = message.presentation {
            PresentationBubble(message: message, presentation: presentation, hud: hud)
        } else if message.role == .system {
            Label(message.text, systemImage: "phone")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom) {
                if isOwner { Spacer(minLength: 48) }
                VStack(alignment: isOwner ? .trailing : .leading, spacing: 4) {
                    bubble
                    footer
                }
                if !isOwner { Spacer(minLength: 48) }
            }
        }
    }

    private var isOwner: Bool { message.role == .owner }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.kind == "missed_call" || message.kind == "declined_call" {
                Label(message.kind == "missed_call" ? "Missed call from \(agentName)" : "You declined a call",
                      systemImage: "phone.arrow.down.left")
                    .font(.caption.bold())
                    .foregroundStyle(hud ? HUD.alert : .red)
            }
            ForEach(message.attachments) { attachment in
                AttachmentView(attachment: attachment, isPlaying: player.playing == attachment.id,
                               open: { open(attachment) }, play: { play(attachment) })
            }
            if let transcript = message.transcript, !transcript.isEmpty {
                Text(transcript).font(.callout.italic()).foregroundStyle(.secondary)
            }
            if !message.text.isEmpty {
                MarkdownText(message.text)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { background }
        .foregroundStyle(isOwner && !hud ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contextMenu {
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
    }

    @ViewBuilder private var background: some View {
        if hud {
            let tint = isOwner ? HUD.light : HUD.glow
            RoundedRectangle(cornerRadius: 16).fill(tint.opacity(isOwner ? 0.1 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.22), lineWidth: 0.75))
        } else {
            RoundedRectangle(cornerRadius: 18).fill(isOwner ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(message.date, style: .time)
            if isOwner { statusIcon }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var statusIcon: some View {
        switch message.status {
        case .pending: Image(systemName: "clock").accessibilityLabel("Waiting to send")
        case .sent: Image(systemName: "checkmark").accessibilityLabel("Sent")
        case .delivered: Image(systemName: "checkmark.circle.fill").accessibilityLabel("Delivered")
        case .failed:
            Button(action: retry) {
                Label("Not delivered – tap to retry", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .received: EmptyView()
        }
    }
}

struct AttachmentView: View {
    let attachment: ChatAttachment
    let isPlaying: Bool
    let open: () -> Void
    let play: () -> Void
    @Environment(ChatModel.self) private var chat
    @State private var image: UIImage?

    var body: some View {
        switch attachment.kind {
        case .photo:
            Button(action: open) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
                    }
                }
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo")
            .task(id: attachment.localFile) { await loadThumbnail() }
        case .voice:
            Button(action: play) {
                Label(voiceLabel, systemImage: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.body.monospacedDigit())
            }
            .buttonStyle(.plain)
            .disabled(attachment.localFile == nil)
        case .file:
            Button(action: open) {
                Label {
                    VStack(alignment: .leading) {
                        Text(attachment.name).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(attachment.localFile == nil)
        }
    }

    private var voiceLabel: String {
        let seconds = Int(attachment.duration ?? 0)
        return seconds > 0 ? "Voice note · \(seconds / 60):\(String(format: "%02d", seconds % 60))" : "Voice note"
    }

    private func loadThumbnail() async {
        guard let url = await chat.attachmentURL(attachment) else { return }
        image = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 660,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }.value
    }
}

/// Agent Markdown: inline styles and links, with ``` fenced blocks shown as code.
struct MarkdownText: View {
    let blocks: [(code: Bool, text: String)]

    init(_ markdown: String) {
        blocks = markdown.components(separatedBy: "```").enumerated().compactMap { index, part in
            let isCode = index % 2 == 1
            let text = isCode ? part.drop { $0 != "\n" }.dropFirst().description : part.trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : (isCode, isCode ? String(text.trimmingCharacters(in: .newlines)) : text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(block.text).font(.callout.monospaced()).padding(8)
                    }
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(Self.attributed(block.text)).textSelection(.enabled)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct TypingIndicator: View {
    let hud: Bool

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.bold())
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
            .foregroundStyle(hud ? HUD.glow : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary))
            .accessibilityLabel("typing")
    }
}

struct ChatApprovalSheet: View {
    let approval: ChatApproval
    @Environment(ChatModel.self) private var chat

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Your assistant wants to run a command that needs your approval.", systemImage: "exclamationmark.shield")
                    .font(.headline)
                if !approval.details.isEmpty {
                    Text(approval.details).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(approval.command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("Approving requires Face ID or your passcode and applies to this one command only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(role: .cancel) { Task { await chat.answerApproval(approve: false) } } label: { Text("Deny").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { Task { await chat.answerApproval(approve: true) } } label: { Text("Approve once").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Approval needed")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
