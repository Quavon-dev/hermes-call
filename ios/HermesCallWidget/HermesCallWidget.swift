import AppIntents
import HermesCallCore
import SwiftUI
import WidgetKit

struct ChatEntry: TimelineEntry {
    let date: Date
    /// The agent the widget shows (nil: none paired yet).
    let agent: AgentInfo?
    let snapshot: ChatSnapshot?
    /// The app uses the HUD appearance.
    let hud: Bool

    var tint: Tint { Tint(agent.flatMap { AgentPalette(rawValue: $0.palette) } ?? SharedContainer.palette) }
    var title: String { agent?.name ?? snapshot?.agentName ?? "Hermes Call" }
    var entity: AgentEntity? { agent.map(AgentEntity.init) }

    /// `hermescall://chat?agent=…` / `hermescall://call?agent=…`, with the app's link secret so a tap calls
    /// at once (links from anywhere else ask first; see DeepLink).
    func url(_ host: String) -> URL {
        LinkSecret.link(host, agent: agent?.id) ?? URL(fileURLWithPath: "/")
    }
}

/// The app reloads the timeline when a message arrives (and the notification extension when it shows
/// one); otherwise once an hour, for renamed agents and the relative time.
struct ChatProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ChatEntry {
        ChatEntry(date: Date(), agent: AgentInfo(id: UUID(), name: "Hermes", palette: AgentPalette.gold.rawValue),
                  snapshot: ChatSnapshot(agentName: "Hermes", preview: "Your backup finished.", date: Date(), fromAgent: true),
                  hud: SharedContainer.usesHUD)
    }

    func snapshot(for configuration: ChatWidgetIntent, in context: Context) async -> ChatEntry {
        context.isPreview && AgentDirectory.agents().isEmpty ? placeholder(in: context) : entry(configuration)
    }

    func timeline(for configuration: ChatWidgetIntent, in context: Context) async -> Timeline<ChatEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(3600)))
    }

    private func entry(_ configuration: ChatWidgetIntent) -> ChatEntry {
        let agents = AgentDirectory.agents()
        let chosen = configuration.agent.flatMap { entity in agents.first { $0.id == entity.id } }
        let agent = chosen ?? agents.first { $0.id == AgentDirectory.activeID() } ?? agents.first
        let snapshot = agent.flatMap { ChatSnapshot.load(profile: $0.id) } ?? (chosen == nil ? ChatSnapshot.load() : nil)
        return ChatEntry(date: Date(), agent: agent, snapshot: snapshot, hud: SharedContainer.usesHUD)
    }
}

/// Widget colours: an agent's presence colour (the active agent's unless given).
struct Tint {
    let palette: AgentPalette

    init(_ palette: AgentPalette = SharedContainer.palette) {
        self.palette = palette
    }

    var glow: Color { Color(palette.glow) }
    var light: Color { Color(palette.light) }
    var ember: Color { Color(palette.ember) }
    static let deep = Color(red: 0.03, green: 0.024, blue: 0.02)
}

extension Color {
    init(_ rgb: AgentPalette.RGB) { self.init(red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b)) }
}

struct ChatWidgetView: View {
    let entry: ChatEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: home
        }
    }

    private var tint: Tint { entry.tint }

    // MARK: Home Screen

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if entry.hud {
                    PresenceEmblem(palette: tint.palette).frame(width: 22, height: 22)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                }
                Text(entry.title).font(entry.hud ? .system(.headline, design: .monospaced) : .headline).lineLimit(1)
                    .foregroundStyle(entry.hud ? tint.light : .primary)
                Spacer(minLength: 0)
            }
            if let snapshot = entry.snapshot {
                Text(snapshot.fromAgent ? snapshot.preview : "You: \(snapshot.preview)")
                    .font(entry.hud ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .foregroundStyle(entry.hud ? tint.light.opacity(0.9) : .primary)
                    .lineLimit(family == .systemSmall ? 3 : 2)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Text(snapshot.date, style: .relative).font(.caption2)
                        .foregroundStyle(entry.hud ? tint.glow.opacity(0.7) : .secondary)
                    Spacer(minLength: 4)
                    buttons
                }
            } else {
                Text("No messages yet").font(.subheadline).foregroundStyle(entry.hud ? tint.glow.opacity(0.7) : .secondary)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    buttons
                }
            }
        }
        .containerBackground(for: .widget) { background }
        .widgetURL(entry.url("chat"))
    }

    /// Interactive: the buttons run their intent in the app (it opens), for this widget's agent.
    private var buttons: some View {
        HStack(spacing: 8) {
            if family != .systemSmall {
                Button(intent: OpenChatIntent(agent: entry.entity)) {
                    Image(systemName: "bubble.left.fill").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(entry.hud ? tint.glow.opacity(0.18) : Color.secondary.opacity(0.18)))
                .foregroundStyle(entry.hud ? tint.light : Color.accentColor)
                .accessibilityLabel("Open the chat")
            }
            Button(intent: CallAgentIntent(agent: entry.entity)) {
                Image(systemName: "phone.fill").font(.body.weight(.semibold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(entry.hud ? tint.glow : Color.accentColor))
            .foregroundStyle(entry.hud ? Tint.deep : .white)
            .accessibilityLabel("Call \(entry.title)")
        }
    }

    @ViewBuilder private var background: some View {
        if entry.hud {
            ZStack {
                Tint.deep
                RadialGradient(colors: [tint.ember.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                PresenceEmblem(palette: tint.palette).opacity(0.18).scaleEffect(1.6).offset(x: 60, y: 30)
            }
        } else {
            Rectangle().fill(.fill.tertiary)
        }
    }

    // MARK: Lock Screen

    /// One tap starts a call.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "phone.fill").font(.title3)
        }
        .widgetURL(entry.url("call"))
        .accessibilityLabel("Call \(entry.title)")
        .containerBackground(.clear, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(entry.title, systemImage: "bubble.left.fill").font(.headline).widgetAccentable()
            Text(entry.snapshot?.preview ?? "No messages yet").font(.caption).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.url("chat"))
        .containerBackground(.clear, for: .widget)
    }

    private var inline: some View {
        Label(entry.snapshot.map { "\(entry.title): \($0.preview)" } ?? entry.title, systemImage: "bubble.left.fill")
            .widgetURL(entry.url("chat"))
            .containerBackground(.clear, for: .widget)
    }
}

/// A still of the presence for widgets (WidgetKit cannot animate): tilted rings around a hot core.
struct PresenceEmblem: View {
    /// Rings filled so far (0…1), e.g. a task's progress; nil = all rings plain.
    var progress: Double?
    var palette: AgentPalette = SharedContainer.palette

    private var tint: Tint { Tint(palette) }

    var body: some View {
        if let still = UIImage(contentsOfFile: SharedContainer.presenceStillURL(palette).path) {
            // The app's own Metal presence, rendered as a still (same look as in the app).
            Image(uiImage: still).resizable().scaledToFit()
                .scaleEffect(1.35)  // the still keeps a soft margin for the glow
                .overlay { if let progress, progress > 0 { ProgressRing(progress: progress, color: tint.light) } }
                .accessibilityHidden(true)
        } else {
            sketch
        }
    }

    /// Fallback until the app has rendered the still in this colour.
    private var sketch: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.blendMode = .plusLighter
            for (index, tilt) in [0.35, -0.9, 1.3].enumerated() {
                let ring = Path(ellipseIn: CGRect(x: -r * 0.92, y: -r * 0.32, width: r * 1.84, height: r * 0.64))
                let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
                context.stroke(ring.applying(transform), with: .color(tint.glow.opacity(0.9 - Double(index) * 0.2)),
                               style: StrokeStyle(lineWidth: max(1, r * 0.06), dash: [r * 0.12, r * 0.06]))
            }
            if let progress, progress > 0 {
                // The outer tasks ring, lit as far as the task got.
                let arc = Path { path in
                    path.addArc(center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, progress)),
                                clockwise: false)
                }
                let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: r * 0.98, y: r * 0.98)
                context.stroke(arc.applying(transform), with: .color(tint.light), style: StrokeStyle(lineWidth: max(1.5, r * 0.08),
                                                                                                   lineCap: .round))
            }
            let bloom = r * 0.45
            context.fill(Path(ellipseIn: CGRect(x: center.x - bloom, y: center.y - bloom, width: bloom * 2, height: bloom * 2)),
                         with: .radialGradient(Gradient(colors: [tint.light, tint.glow.opacity(0.4), .clear]),
                                               center: center, startRadius: 0, endRadius: bloom))
        }
        .accessibilityHidden(true)
    }
}

/// The tasks ring around the still: lit as far as the task got.
private struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        Circle().trim(from: 0, to: min(1, progress))
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1)
    }
}

struct ChatWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "HermesCallChat", intent: ChatWidgetIntent.self, provider: ChatProvider()) { entry in
            ChatWidgetView(entry: entry)
        }
        .configurationDisplayName("Hermes Chat")
        .description("An agent's latest message, with buttons to open the chat or call. On the Lock Screen: call or read it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Control Center / Lock Screen / Action button: runs `CallAgentIntent` in the app.
struct CallControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.quavon.hermescall.call") {
            ControlWidgetButton(action: CallAgentIntent()) {
                Label("Call Hermes", systemImage: "phone.fill")
            }
        }
        .displayName("Call Hermes")
        .description("Starts a voice call with your agent.")
    }
}

/// Control Center / Lock Screen / Action button: runs `StopAgentIntent` in the app's process, without its UI.
struct StopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.quavon.hermescall.stop") {
            ControlWidgetButton(action: StopAgentIntent()) {
                Label("Stop Agent", systemImage: "stop.circle.fill")
            }
        }
        .displayName("Stop Agent")
        .description("Stops what your agent is doing right now.")
    }
}

@main
struct HermesCallWidgets: WidgetBundle {
    var body: some Widget {
        ChatWidget()
        CallControl()
        StopControl()
        TaskLiveActivity()
    }
}
