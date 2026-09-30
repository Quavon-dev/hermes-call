import SwiftUI
import WidgetKit

struct EmblemEntry: TimelineEntry {
    let date: Date
    let name: String
    let palette: WatchPalette
}

struct EmblemProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmblemEntry { entry() }
    func getSnapshot(in context: Context, completion: @escaping (EmblemEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EmblemEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> EmblemEntry {
        let shared = WatchPalette.shared
        return EmblemEntry(date: Date(), name: shared.name, palette: shared.palette)
    }
}

/// A still presence; tapping any complication opens the watch app.
struct EmblemView: View {
    let entry: EmblemEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack {
                emblem.frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(entry.name).font(.headline).widgetAccentable()
                    Text("Tap to talk").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Label(entry.name, systemImage: "circle.hexagongrid.fill").containerBackground(.clear, for: .widget)
        default:
            ZStack {
                AccessoryWidgetBackground()
                emblem.padding(3)
            }
            .containerBackground(.clear, for: .widget)
        }
    }

    private var emblem: some View {
        Canvas { context, size in
            PresenceSketch.draw(&context, size: size, time: 0.8, glow: entry.palette.glow, light: entry.palette.light,
                                ember: entry.palette.ember)
        }
        .widgetAccentable()
        .accessibilityLabel("Call \(entry.name)")
    }
}

@main
struct HermesCallWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HermesCallWatchEmblem", provider: EmblemProvider()) { entry in
            EmblemView(entry: entry)
        }
        .configurationDisplayName("Hermes")
        .description("Your agent's presence. Tap to open.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
