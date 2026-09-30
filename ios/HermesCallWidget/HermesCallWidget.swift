import AppIntents
import HermesCallCore
import SwiftUI
import WidgetKit

private let callURL = URL(string: "hermescall://call")!
private let chatURL = URL(string: "hermescall://chat")!

struct ChatEntry: TimelineEntry {
    let date: Date
    let snapshot: ChatSnapshot?
    /// The app uses the gold HUD appearance.
    let hud: Bool
}

struct ChatProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChatEntry {
        ChatEntry(date: Date(), snapshot: ChatSnapshot(agentName: "Hermes", preview: "Your backup finished.", date: Date(), fromAgent: true),
                  hud: SharedContainer.usesHUD)
    }

    func getSnapshot(in context: Context, completion: @escaping (ChatEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChatEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> ChatEntry {
        ChatEntry(date: Date(), snapshot: ChatSnapshot.load(), hud: SharedContainer.usesHUD)
    }
}

/// Widget palette: the active agent's presence colour in HUD appearance (gold by default), system colours otherwise.
enum Gold {
    static var glow: Color { Color(SharedContainer.palette.glow) }
    static var light: Color { Color(SharedContainer.palette.light) }
    static var ember: Color { Color(SharedContainer.palette.ember) }
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

    // MARK: Home Screen

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if entry.hud {
                    PresenceEmblem().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                }
                Text(title).font(entry.hud ? .system(.headline, design: .monospaced) : .headline).lineLimit(1)
                    .foregroundStyle(entry.hud ? Gold.light : .primary)
                Spacer(minLength: 0)
                if family != .systemSmall {
                    Link(destination: callURL) {
                        Image(systemName: "phone.circle.fill").font(.title2).foregroundStyle(entry.hud ? Gold.glow : Color.accentColor)
                    }
                    .accessibilityLabel("Call")
                }
            }
            if let snapshot = entry.snapshot {
                Text(snapshot.fromAgent ? snapshot.preview : "You: \(snapshot.preview)")
                    .font(entry.hud ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .foregroundStyle(entry.hud ? Gold.light.opacity(0.9) : .primary)
                    .lineLimit(family == .systemSmall ? 4 : 3)
                Spacer(minLength: 0)
                Text(snapshot.date, style: .relative).font(.caption2)
                    .foregroundStyle(entry.hud ? Gold.glow.opacity(0.7) : .secondary)
            } else {
                Text("No messages yet").font(.subheadline).foregroundStyle(entry.hud ? Gold.glow.opacity(0.7) : .secondary)
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { background }
        .widgetURL(chatURL)
    }

    @ViewBuilder private var background: some View {
        if entry.hud {
            ZStack {
                Gold.deep
                RadialGradient(colors: [Gold.ember.opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                PresenceEmblem().opacity(0.18).scaleEffect(1.6).offset(x: 60, y: 30)
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
        .widgetURL(callURL)
        .accessibilityLabel("Call \(title)")
        .containerBackground(.clear, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: "bubble.left.fill").font(.headline).widgetAccentable()
            Text(entry.snapshot?.preview ?? "No messages yet").font(.caption).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(chatURL)
        .containerBackground(.clear, for: .widget)
    }

    private var inline: some View {
        Label(entry.snapshot.map { "\(title): \($0.preview)" } ?? title, systemImage: "bubble.left.fill")
            .widgetURL(chatURL)
            .containerBackground(.clear, for: .widget)
    }

    private var title: String { entry.snapshot?.agentName ?? "Hermes Call" }
}

/// A still of the presence for widgets (WidgetKit cannot animate): tilted rings around a hot core.
struct PresenceEmblem: View {
    /// Rings filled so far (0…1), e.g. a task's progress; nil = all rings plain.
    var progress: Double?

    var body: some View {
        if let still = UIImage(contentsOfFile: SharedContainer.presenceStillURL(SharedContainer.palette).path) {
            // The app's own Metal presence, rendered as a still (same look as in the app).
            Image(uiImage: still).resizable().scaledToFit()
                .scaleEffect(1.35)  // the still keeps a soft margin for the glow
                .overlay { if let progress, progress > 0 { ProgressRing(progress: progress) } }
                .accessibilityHidden(true)
        } else {
            sketch
        }
    }

    /// Fallback until the app has rendered the still once.
    private var sketch: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.blendMode = .plusLighter
            for (index, tilt) in [0.35, -0.9, 1.3].enumerated() {
                let ring = Path(ellipseIn: CGRect(x: -r * 0.92, y: -r * 0.32, width: r * 1.84, height: r * 0.64))
                let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
                context.stroke(ring.applying(transform), with: .color(Gold.glow.opacity(0.9 - Double(index) * 0.2)),
                               style: StrokeStyle(lineWidth: max(1, r * 0.06), dash: [r * 0.12, r * 0.06]))
            }
            if let progress, progress > 0 {
                // The outer tasks ring, lit as far as the task got.
                let arc = Path { path in
                    path.addArc(center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, progress)),
                                clockwise: false)
                }
                let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: r * 0.98, y: r * 0.98)
                context.stroke(arc.applying(transform), with: .color(Gold.light), style: StrokeStyle(lineWidth: max(1.5, r * 0.08),
                                                                                                    lineCap: .round))
            }
            let bloom = r * 0.45
            context.fill(Path(ellipseIn: CGRect(x: center.x - bloom, y: center.y - bloom, width: bloom * 2, height: bloom * 2)),
                         with: .radialGradient(Gradient(colors: [Gold.light, Gold.glow.opacity(0.4), .clear]),
                                               center: center, startRadius: 0, endRadius: bloom))
        }
        .accessibilityHidden(true)
    }
}

/// The tasks ring around the still: lit as far as the task got.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        Circle().trim(from: 0, to: min(1, progress))
            .stroke(Gold.light, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1)
    }
}

struct ChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HermesCallChat", provider: ChatProvider()) { entry in
            ChatWidgetView(entry: entry)
        }
        .configurationDisplayName("Hermes Chat")
        .description("The latest message from your agent. On the Lock Screen: call or read it.")
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

@main
struct HermesCallWidgets: WidgetBundle {
    var body: some Widget {
        ChatWidget()
        CallControl()
        TaskLiveActivity()
    }
}
