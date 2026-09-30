import HermesCallCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → Hermes Call": sends links, text, photos and files to the agent's chat. The message goes into
/// the chat's outbox in the app group; a running app sends it over its own relay connection (the relay
/// keeps one connection per device, so the extension must not take it over). Only when the app does not
/// answer does the extension connect itself (`ShareHandoff`); anything unconfirmed stays in the outbox.
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

    /// Attachments per chat message (the bridge takes at most four).
    static let maxFiles = 4

    var comment = ""
    var profileID: UUID?
    private(set) var profiles: [RelayProfile] = []
    private(set) var texts: [String] = []
    private(set) var files: [SharedFile] = []
    /// Items that were not taken: more than `maxFiles` files, too large or unreadable.
    private(set) var leftOut = 0
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
        // The agent that is active in the app, like the app's own chat.
        let active = AgentDirectory.activeID()
        profileID = profiles.first { $0.id == active }?.id ?? profiles.first?.id
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            await load(provider)
        }
        phase = profiles.isEmpty ? .failed("Pair Hermes Call with your bridge first.") : .ready
    }

    private func load(_ provider: NSItemProvider) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            texts.append(url.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                  !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                  let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            texts.append(text)
        } else if files.count >= Self.maxFiles {
            leftOut += 1
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard let data = try? await Self.data(provider, type: .image), let jpeg = PhotoEncoder.jpeg(data) else {
                leftOut += 1
                return
            }
            files.append(SharedFile(kind: .photo, name: "Photo \(files.count + 1).jpg", mime: "image/jpeg", data: jpeg))
        } else if let type = provider.registeredContentTypes.first, let data = try? await Self.data(provider, type: type),
                  data.count <= Blob.maxPlaintext {
            let name = provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "bin")" } ?? "File"
            files.append(SharedFile(kind: .file, name: name, mime: type.preferredMIMEType ?? "application/octet-stream", data: data))
        } else {
            leftOut += 1
        }
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func send() async {
        guard let profile else { return }
        phase = .sending
        let text = ([comment.trimmingCharacters(in: .whitespacesAndNewlines)] + texts).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var message = ChatMessage(id: E2EChannel.newMessageID(), role: .owner, text: String(text.prefix(ChatWire.maxText)), status: .pending)
        let store = ChatStore.shared
        do {
            for file in files.prefix(Self.maxFiles) {
                var attachment = ChatAttachment(kind: file.kind, name: file.name, mime: file.mime, size: file.data.count)
                attachment.localFile = try await store.saveAttachment(file.data, id: attachment.id, name: file.name, in: profile.id)
                message.attachments.append(attachment)
            }
            try await store.upsert(message, in: profile.id)
        } catch {
            phase = .failed("The message could not be saved.")
            return
        }
        let stored = message
        _ = await ShareHandoff.deliver(stored, profile: profile.id, store: store, appIsRunning: { await SharedSignal.probe() },
                                       sendHere: { await Self.deliver(stored, profile: profile, store: store) })
        done()
    }

    /// Only when the app is not running: its own connection, up to 25 s.
    private static func deliver(_ message: ChatMessage, profile: RelayProfile, store: ChatStore) async -> Bool {
        guard let session = try? RelaySession(profile: profile, acceptsMail: false) else { return false }
        do {
            try await session.waitUntilConnected(timeout: 10)
            var uploads: [(attachment: ChatAttachment, blobID: String, key: Data)] = []
            let directory = await store.attachmentDirectory(profile.id)
            for attachment in message.attachments {
                guard let file = attachment.localFile else { continue }
                let (key, sealed) = try Blob.seal(try Data(contentsOf: directory.appendingPathComponent(file)))
                uploads.append((attachment, try await session.uploadBlob(sealed), key))
            }
            try await session.send(ChatWire.body(for: message, uploads: uploads), mail: true)
            let confirmed = await withTaskGroup(of: Bool.self) { group in
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
                return result
            }
            await session.stop()
            return confirmed
        } catch {
            await session.stop()
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
                        Section {
                            ForEach(model.texts, id: \.self) { Label($0, systemImage: "link").lineLimit(2) }
                            ForEach(model.files) { file in
                                Label(file.name, systemImage: file.kind == .photo ? "photo" : "doc")
                            }
                        } header: {
                            Text("Sharing")
                        } footer: {
                            if model.leftOut > 0 {
                                Text(model.leftOut == 1
                                     ? "1 item is left out: a message takes up to \(ShareModel.maxFiles) files of at most 10 MB each."
                                     : "\(model.leftOut) items are left out: a message takes up to \(ShareModel.maxFiles) files of at most 10 MB each.")
                                    .foregroundStyle(.orange)
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
