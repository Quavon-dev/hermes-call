import HermesCallCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → Hermes Call": sends links, text, photos and files to the agent's chat. The extension
/// talks to the relay itself; if the bridge does not confirm in time, the message stays in the
/// chat's outbox and the app resends it.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel(items: items) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

struct SharedFile: Identifiable, Sendable {
    let id = UUID()
    let kind: ChatAttachment.Kind
    let name: String
    let mime: String
    let data: Data
}

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable { case loading, ready, sending, failed(String) }

    var comment = ""
    var profileID: UUID?
    private(set) var profiles: [RelayProfile] = []
    private(set) var texts: [String] = []
    private(set) var files: [SharedFile] = []
    private(set) var phase: Phase = .loading
    private let items: [NSExtensionItem]
    private let done: () -> Void
    let cancel: () -> Void

    init(items: [NSExtensionItem], done: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.items = items
        self.done = done
        self.cancel = cancel
    }

    var profile: RelayProfile? { profiles.first { $0.id == profileID } ?? profiles.first }

    func load() async {
        profiles = (try? ProfileStore().load()) ?? []
        profileID = profiles.first?.id
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            await load(provider)
        }
        phase = profiles.isEmpty ? .failed("Pair Hermes Call with your bridge first.") : .ready
    }

    private func load(_ provider: NSItemProvider) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            texts.append(url.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                  let data = try? await Self.data(provider, type: .image), let jpeg = Self.jpeg(data) {
            files.append(SharedFile(kind: .photo, name: "Photo \(files.count + 1).jpg", mime: "image/jpeg", data: jpeg))
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                  let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            texts.append(text)
        } else if let type = provider.registeredContentTypes.first, let data = try? await Self.data(provider, type: type),
                  data.count <= Blob.maxPlaintext {
            let name = provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "bin")" } ?? "File"
            files.append(SharedFile(kind: .file, name: name, mime: type.preferredMIMEType ?? "application/octet-stream", data: data))
        }
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private static func jpeg(_ data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.82)
    }

    func send() async {
        guard let profile else { return }
        phase = .sending
        let text = ([comment.trimmingCharacters(in: .whitespacesAndNewlines)] + texts).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var message = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: String(text.prefix(ChatWire.maxText)), status: .pending)
        let store = ChatStore.shared
        do {
            for file in files.prefix(4) {
                var attachment = ChatAttachment(kind: file.kind, name: file.name, mime: file.mime, size: file.data.count)
                attachment.localFile = try await store.saveAttachment(file.data, id: attachment.id, name: file.name, in: profile.id)
                message.attachments.append(attachment)
            }
            try await store.upsert(message, in: profile.id)
        } catch {
            phase = .failed("The message could not be saved.")
            return
        }
        let delivered = await Self.deliver(message, files: files, profile: profile)
        try? await store.update(message.id, in: profile.id) { $0.status = delivered ? .delivered : .pending }
        done()
    }

    /// Up to 15 s; otherwise the app's outbox takes over.
    private static func deliver(_ message: ChatMessage, files: [SharedFile], profile: RelayProfile) async -> Bool {
        guard let session = try? RelaySession(profile: profile, acceptsMail: false) else { return false }
        defer { Task { await session.stop() } }
        do {
            try await session.waitUntilConnected(timeout: 10)
            var uploads: [(attachment: ChatAttachment, blobID: String, key: Data)] = []
            for (attachment, file) in zip(message.attachments, files) {
                let (key, sealed) = try Blob.seal(file.data)
                uploads.append((attachment, try await session.uploadBlob(sealed), key))
            }
            try await session.send(ChatWire.body(for: message, uploads: uploads), mail: true)
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await body in session.messages where body["type"]?.string == "chat_ack" && body["id"]?.string == message.id {
                        return true
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(15))
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                await session.stop()
                return result
            }
        } catch {
            return false
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if case .failed(let reason) = model.phase {
                    Text(reason).foregroundStyle(.secondary)
                } else {
                    if model.profiles.count > 1 {
                        Picker("To", selection: $model.profileID) {
                            ForEach(model.profiles) { Text("\($0.bridgeName) · \($0.label)").tag(Optional($0.id)) }
                        }
                    }
                    Section {
                        TextField("Add a message", text: $model.comment, axis: .vertical).lineLimit(2...6)
                    }
                    if !model.texts.isEmpty || !model.files.isEmpty {
                        Section("Sharing") {
                            ForEach(model.texts, id: \.self) { Label($0, systemImage: "link").lineLimit(2) }
                            ForEach(model.files) { file in
                                Label(file.name, systemImage: file.kind == .photo ? "photo" : "doc")
                            }
                        }
                    }
                    Section {
                        Label("End-to-end encrypted to your bridge.", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(model.profile.map { "To \($0.bridgeName)" } ?? "Hermes Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: model.cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .sending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await model.send() } }
                            .disabled(model.phase != .ready || (model.comment.isEmpty && model.texts.isEmpty && model.files.isEmpty))
                    }
                }
            }
        }
    }
}
