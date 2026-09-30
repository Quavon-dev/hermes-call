import AVFoundation
import SwiftUI
import UserNotifications

/// First launch: what Hermes Call is (your agent, your bridge, your relay), the permissions it will ask
/// for and why (asked here, before iOS' own prompt), then pair with your relay or try the offline demo.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    @State private var addingRelay = false

    static let setupGuide = URL(string: "https://github.com/Quavon-dev/hermes-call#readme")
    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                HowItWorksPage().tag(1)
                PermissionsPage().tag(2)
                StartPage(addRelay: { addingRelay = true }, tryDemo: { app.startDemo() }).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            // Always laid out (hidden on the last page), so the page dots never jump.
            Button {
                withAnimation { page = min(page + 1, Self.pageCount - 1) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .opacity(page < Self.pageCount - 1 ? 1 : 0)
            .disabled(page == Self.pageCount - 1)
            .accessibilityHidden(page == Self.pageCount - 1)
            .accessibilityIdentifier("onboarding.continue")
        }
        .sheet(isPresented: $addingRelay) { AddRelayView() }
    }
}

// MARK: pages

private struct Page<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(.largeTitle).weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 56)
        }
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        Page(symbol: "phone.bubble.fill", title: "Your own agent, on the phone") {
            Text("Call your Hermes agent like a person, chat with it, and let it call you when something needs you.")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Point(symbol: "phone.fill", text: "Real phone calls through CallKit, also from the lock screen.")
                Point(symbol: "bubble.left.and.bubble.right.fill", text: "Chat with photos, files and voice notes.")
                Point(symbol: "checkmark.shield.fill", text: "Commands only run after you approve them with Face ID.")
            }
        }
    }
}

private struct HowItWorksPage: View {
    var body: some View {
        Page(symbol: "point.3.connected.trianglepath.dotted", title: "Three pieces, all yours") {
            Part(symbol: "brain.head.profile", name: "Agent",
                 text: "Hermes, the AI agent you run on your own computer or server.")
            Part(symbol: "arrow.left.arrow.right", name: "Bridge",
                 text: "Runs next to your agent and turns calls and messages into its conversations.")
            Part(symbol: "antenna.radiowaves.left.and.right", name: "Relay",
                 text: "A small server you host that connects this iPhone to your bridge from anywhere. It forwards "
                     + "only encrypted data.")
            Point(symbol: "lock.fill", text: "Everything between this iPhone and your bridge is end-to-end encrypted. "
                  + "No accounts, no cloud service of ours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private struct Part: View {
        let symbol: String
        let name: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Explains each permission before iOS asks; "Allow" shows iOS' prompt, skipping is fine.
private struct PermissionsPage: View {
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var notifications: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Page(symbol: "hand.raised.fill", title: "Two permissions") {
            Text("iOS asks for each once. You can change them later in Settings.")
                .foregroundStyle(.secondary)
            Permission(symbol: "mic.fill", title: "Microphone",
                       text: "For calls with your agent and voice notes. Only while you are on a call or recording.",
                       granted: microphone == .granted, denied: microphone == .denied) {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    microphone = AVAudioApplication.shared.recordPermission
                }
            }
            Permission(symbol: "bell.badge.fill", title: "Notifications",
                       text: "So your agent's messages and questions reach you when the app is closed. Incoming calls "
                           + "ring without this.",
                       granted: notifications == .authorized, denied: notifications == .denied) {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    await refresh()
                }
            }
            Text("Camera, location, calendar and the rest are asked only when you use them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private struct Permission: View {
        let symbol: String
        let title: String
        let text: String
        let granted: Bool
        let denied: Bool
        let allow: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if granted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium)).foregroundStyle(.green)
                    } else if denied {
                        Button("Turn on in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.subheadline.weight(.medium))
                    } else {
                        Button("Allow \(title.lowercased())", action: allow)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("onboarding.allow.\(title.lowercased())")
                    }
                }
            }
        }
    }
}

private struct StartPage: View {
    let addRelay: () -> Void
    let tryDemo: () -> Void

    var body: some View {
        Page(symbol: "qrcode.viewfinder", title: "Connect your agent") {
            Text("On the computer that runs your bridge, run")
                .foregroundStyle(.secondary)
            Text("hermes-call-bridge device add")
                .font(.callout.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)
            Text("It shows a QR code and a pairing code. Scan it here, or open the hermescall:// link on this iPhone.")
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button(action: addRelay) { Text("Add your relay").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.addRelay")
                Button(action: tryDemo) { Text("Try a demo").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.demo")
            }
            .padding(.top, 8)
            Text("The demo agent runs on this iPhone, offline; nothing is sent anywhere. Remove it any time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let guide = OnboardingView.setupGuide {
                Link(destination: guide) {
                    Label("No bridge yet? Set one up", systemImage: "book")
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }
}
