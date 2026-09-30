import HermesCallCore
import MapKit
import SwiftUI

/// Opens a card action: Safari for https links, Phone for numbers, Maps for places.
@MainActor
enum CardActions {
    static func url(for action: Presentation.Action, item: Presentation.Item) -> URL? {
        switch action.target {
        case .url(let url): url
        case .tel(let number): Presentation.telURL(number)
        case .maps: mapsURL(item)
        }
    }

    static func mapsURL(_ item: Presentation.Item) -> URL? {
        guard let lat = item.latitude, let lon = item.longitude else { return nil }
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lon)"), URLQueryItem(name: "q", value: item.title)]
        return components?.url
    }

    static func symbol(_ action: Presentation.Action) -> String {
        switch action.target {
        case .url: "safari"
        case .tel: "phone.fill"
        case .maps: "map.fill"
        }
    }
}

/// A card image stored with the chat (fetched by the bridge, never by the phone).
struct CardImage: View {
    let image: Presentation.Image?
    var height: CGFloat = 96
    @Environment(ChatModel.self) private var chat
    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: image?.localFile) {
            guard let url = await chat.fileURL(image?.localFile) else { return }
            loaded = await Task.detached(priority: .utility) { (try? Data(contentsOf: url)).flatMap(UIImage.init(data:)) }.value
        }
        .accessibilityHidden(true)
    }
}

/// One result: image, title, subtitle, a little detail and up to three actions.
struct ResultCard: View {
    let item: Presentation.Item
    let hud: Bool
    var width: CGFloat = 220
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.image?.localFile != nil { CardImage(image: item.image).clipShape(RoundedRectangle(cornerRadius: 10)) }
            Text(item.title).font(.headline).lineLimit(2)
                .foregroundStyle(hud ? HUD.light : .primary)
            if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            Spacer(minLength: 0)
            if !item.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                        Button {
                            if let url = CardActions.url(for: action, item: item) { openURL(url) }
                        } label: {
                            // Three labels do not fit a card: icons only (full labels in the detail view).
                            Label(action.label, systemImage: CardActions.symbol(action)).font(.caption.bold()).lineLimit(1)
                                .labelStyle(CardActionLabelStyle(iconOnly: item.actions.count > 2))
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel(action.label)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 150, alignment: .topLeading)
        .background { if !hud { cardBackground } }
        .modifier(HUDCardSurface(on: hud))
        .contentShape(Rectangle())
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(.background.secondary)
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius).stroke(.quaternary))
    }
}

private struct HUDCardSurface: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.hudSurface(cornerRadius: Metrics.cornerRadius) } else { content }
    }
}

private struct CardActionLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// Pins of all located items (Apple Maps tiles only; no other network).
struct ResultsMap: View {
    let items: [Presentation.Item]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(items.filter(\.hasLocation)) { item in
                Marker(item.title, coordinate: CLLocationCoordinate2D(latitude: item.latitude ?? 0, longitude: item.longitude ?? 0))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

/// The chat bubble for a presentation: title, optional map, a horizontal row of cards.
struct PresentationBubble: View {
    let message: ChatMessage
    let presentation: Presentation
    let hud: Bool
    @Environment(ChatModel.self) private var chat
    @State private var selected: Presentation.Item?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(presentation.title, systemImage: symbol).font(.subheadline.bold())
                    .foregroundStyle(hud ? HUD.light : .primary)
                Spacer()
                if hud {
                    Button { chat.showOnPresence(message) } label: { Image(systemName: "sparkles") }
                        .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                        .accessibilityLabel("Show on the presence")
                }
            }
            if !message.text.isEmpty && message.text != presentation.title {
                Text(message.text).font(.callout)
            }
            if presentation.kind == .places, presentation.items.contains(where: \.hasLocation) {
                ResultsMap(items: presentation.items).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(presentation.items) { item in
                        ResultCard(item: item, hud: hud).onTapGesture { selected = item }
                    }
                }
                .padding(.vertical, 2)
            }
            Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(item: $selected) { ResultDetail(item: $0, hud: hud).agentTheme() }
    }

    private var symbol: String {
        switch presentation.kind {
        case .places: "mappin.and.ellipse"
        case .links: "link"
        case .list: "list.bullet.rectangle"
        }
    }
}

/// Full card: everything the agent sent, a map for places, the actions.
struct ResultDetail: View {
    let item: Presentation.Item
    let hud: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if item.image?.localFile != nil { CardImage(image: item.image, height: 200).clipShape(RoundedRectangle(cornerRadius: 14)) }
                    Text(item.title).font(.title2.bold())
                    if let subtitle = item.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    if let detail = item.detail { Text(detail) }
                    if item.hasLocation { ResultsMap(items: [item]).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14)) }
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                        Button {
                            if let url = CardActions.url(for: action, item: item) { openURL(url) }
                        } label: {
                            Label(action.label, systemImage: CardActions.symbol(action))
                                .frame(maxWidth: .infinity, minHeight: Metrics.controlHeight)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let url = item.url {
                        Link(destination: url) {
                            Label(url.host() ?? "Open link", systemImage: "safari").frame(maxWidth: .infinity, minHeight: Metrics.controlHeight)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .hudStyle(hud)
    }
}
