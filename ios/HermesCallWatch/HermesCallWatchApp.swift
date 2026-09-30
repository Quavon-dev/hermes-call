import SwiftUI

@main
struct HermesCallWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView().environment(model)
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            TabView {
                WatchPresenceView()
                WatchMessagesView()
            }
            .tabViewStyle(.verticalPage)
        }
        .tint(model.palette.glow)
    }
}

/// The presence fills the screen: tap it to call (the call runs on the iPhone); the bottom bar
/// dictates a message or calls.
struct WatchPresenceView: View {
    @Environment(WatchModel.self) private var model
    @State private var composing = false
    @State private var pressed = false

    var body: some View {
        let palette = model.palette
        VStack(spacing: 4) {
            presence
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(pressed ? 1.06 : 1)
                .animation(.spring(duration: 0.35), value: pressed)
                .contentShape(Rectangle())
                .onTapGesture(perform: call)
                .accessibilityElement()
                .accessibilityLabel("Call \(model.snapshot.agentName)")
                .accessibilityAddTraits(.isButton)
            Text(model.status ?? (model.snapshot.paired ? "tap to call" : "Pair on your iPhone first"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.status == nil ? palette.glow.opacity(0.7) : palette.light)
                .multilineTextAlignment(.center)
            // Kept clear of the rounded screen edges.
            HStack {
                roundButton("mic.fill", fill: palette.ember, ink: palette.light, label: "Dictate a message") { composing = true }
                Spacer()
                roundButton("phone.fill", fill: palette.glow, ink: .black, label: "Call", action: call)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
        .navigationTitle(model.snapshot.agentName)
        .sheet(isPresented: $composing) { WatchComposeView() }
        .containerBackground(Color.black.gradient, for: .tabView)
        .disabled(!model.snapshot.paired)
    }

    /// The iPhone's rendered presence (same look as the app), breathing; a drawn sketch until it arrives.
    @ViewBuilder private var presence: some View {
        let palette = model.palette
        if let still = model.still {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Image(uiImage: still).resizable().scaledToFit()
                    .scaleEffect(1.45 * (1 + 0.025 * sin(t * 1.6)))
                    .brightness(0.04 * sin(t * 2.3) + (pressed ? 0.15 : 0))
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    PresenceSketch.draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate,
                                        glow: palette.glow, light: palette.light, ember: palette.ember,
                                        energy: pressed ? 1 : 0.45)
                }
            }
        }
    }

    private func roundButton(_ symbol: String, fill: Color, ink: Color, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                .frame(width: 44, height: 44).background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func call() {
        pressed = true
        model.call()
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            pressed = false
        }
    }
}

/// Dictate (or scribble) a message; sent through the iPhone.
struct WatchComposeView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 10) {
            TextField("Dictate a message", text: $draft).submitLabel(.send).onSubmit(send)
            Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .tint(model.palette.glow)
        }
        .navigationTitle(model.snapshot.agentName)
    }

    private func send() {
        model.sendMessage(draft)
        dismiss()
    }
}

/// The agent's latest messages (text only when the iPhone shows message text in notifications).
struct WatchMessagesView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let palette = model.palette
        List {
            if model.snapshot.messages.isEmpty {
                Text("No messages yet").foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.messages.reversed()) { message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.fromAgent ? model.snapshot.agentName : "You")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(message.fromAgent ? palette.glow : .secondary)
                    Text(message.text).font(.footnote).foregroundStyle(message.fromAgent ? palette.light : .primary)
                    Text(message.date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(Color.black.gradient, for: .tabView)
        .navigationTitle("Messages")
    }
}
