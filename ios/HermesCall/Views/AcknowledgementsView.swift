import SwiftUI

/// Settings › Acknowledgements: the open-source software inside the app, with its licences
/// (the texts are bundled from Resources/Licenses).
struct AcknowledgementsView: View {
    struct Component: Identifiable {
        let name: String
        let detail: String
        let licence: String
        let file: String
        var id: String { name }
    }

    static let components = [
        Component(name: "WebRTC", detail: "Audio calls. Google's WebRTC, packaged by stasel/WebRTC. The binary also "
                  + "contains WebRTC's own dependencies (BoringSSL, Opus, libsrtp, Abseil and others) under their "
                  + "licences, listed at webrtc.googlesource.com/src/+/main/third_party.",
                  licence: "BSD-3-Clause", file: "WebRTC"),
        Component(name: "libsodium", detail: "Encryption (X25519, Ed25519, XChaCha20-Poly1305).", licence: "ISC",
                  file: "libsodium"),
        Component(name: "swift-sodium", detail: "libsodium for Swift (its Clibsodium build).", licence: "ISC",
                  file: "swift-sodium"),
        Component(name: "CPace", detail: "Password-authenticated pairing (jedisct1/cpace).", licence: "BSD-2-Clause",
                  file: "CPace"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.components) { component in
                    DisclosureGroup {
                        Text(Self.text(component.file))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(component.name).font(.headline)
                                Spacer()
                                Text(component.licence).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(component.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Hermes Call is open source under the MIT licence. Its icons and the presence are original work.")
            }
        }
        .navigationTitle("Acknowledgements")
    }

    static func text(_ file: String) -> String {
        Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Licence text missing."
    }
}
