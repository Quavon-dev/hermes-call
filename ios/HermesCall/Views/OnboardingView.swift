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
            .tabViewStyle(.page(indexDisplayMode: .never))
            PageDots(count: Self.pageCount, current: page).padding(.vertical, 14)
            // Always laid out (hidden on the last page), so the dots never jump.
            Button {
                withAnimation(.smooth(duration: 0.35)) { page = min(page + 1, Self.pageCount - 1) }
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .opacity(page < Self.pageCount - 1 ? 1 : 0)
            .disabled(page == Self.pageCount - 1)
            .accessibilityHidden(page == Self.pageCount - 1)
            .accessibilityIdentifier("onboarding.continue")
        }
        .background { AmbientBackground() }
        .sheet(isPresented: $addingRelay) { AddRelayView().agentTheme() }
    }
}

/// Where you are in the pages: the current one a longer capsule.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: pages

private struct Page<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { space in
            ScrollView {
                VStack(spacing: 22) {
                    Orb(symbol: symbol)
                    VStack(spacing: 10) {
                        Text(title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle).font(.body).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)
                // Short pages sit in the middle instead of leaving the lower half empty.
                .frame(minHeight: space.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The page's symbol in a glowing ball of the agent's colour.
private struct Orb: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .frame(width: 112, height: 112)
            .background {
                Circle().fill(LinearGradient(colors: [HUD.glow, HUD.alert, HUD.ownerBubble], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                                             lineWidth: 1.5))
            }
            .background { Circle().fill(HUD.glow.opacity(0.5)).blur(radius: 36).scaleEffect(1.2) }
            .accessibilityHidden(true)
    }
}

/// A glass card holding a page's rows.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }
}

/// A row's symbol: white on a small tile of the agent's colour.
private struct Tile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 11).fill(LinearGradient(colors: [HUD.glow, HUD.alert], startPoint: .top, endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Tile(symbol: symbol)
            Text(text).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        Page(symbol: "phone.bubble.fill", title: "Your own agent, on the phone",
             subtitle: "Call your Hermes agent like a person, chat with it, and let it call you when something needs you.") {
            Card {
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
            Card {
                Part(symbol: "brain.head.profile", name: "Agent",
                     text: "Hermes, the AI agent you run on your own computer or server.")
                Part(symbol: "arrow.left.arrow.right", name: "Bridge",
                     text: "Runs next to your agent and turns calls and messages into its conversations.")
                Part(symbol: "antenna.radiowaves.left.and.right", name: "Relay",
                     text: "A small server you host that connects this iPhone to your bridge from anywhere. It forwards "
                         + "only encrypted data.")
            }
            Label("End-to-end encrypted between this iPhone and your bridge. No accounts, no cloud service of ours.",
                  systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct Part: View {
        let symbol: String
        let name: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Tile(symbol: symbol)
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
        Page(symbol: "hand.raised.fill", title: "Two permissions",
             subtitle: "iOS asks for each once. You can change them later in Settings.") {
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
                .multilineTextAlignment(.center)
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
                Tile(symbol: symbol)
                VStack(alignment: .leading, spacing: 8) {
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
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("onboarding.allow.\(title.lowercased())")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        }
    }
}

private struct StartPage: View {
    let addRelay: () -> Void
    let tryDemo: () -> Void

    var body: some View {
        Page(symbol: "qrcode.viewfinder", title: "Connect your agent") {
            Card {
                Text("On the computer that runs your bridge, run")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("hermes-call-bridge device add")
                    .font(.callout.monospaced().weight(.medium))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
                Text("It shows a QR code and a pairing code. Scan it here, or open the hermescall:// link on this iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button(action: addRelay) {
                        Label("Add your relay", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("onboarding.addRelay")
                    Button(action: tryDemo) {
                        Label("Try a demo", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("onboarding.demo")
                }
            }
            Text("The demo agent runs on this iPhone, offline; nothing is sent anywhere. Remove it any time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let guide = OnboardingView.setupGuide {
                Link(destination: guide) {
                    Label("No bridge yet? Set one up", systemImage: "book")
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}
