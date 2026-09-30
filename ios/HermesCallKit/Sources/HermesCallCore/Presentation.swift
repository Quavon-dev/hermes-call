import Foundation

/// Structured results the agent shows the owner (places, links, lists) — docs/protocol.md, "Presentations".
/// Everything is plain text; links are https only, so a card can never run script or reach a local address.
public struct Presentation: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case places, links, list }

    public struct Action: Codable, Sendable, Hashable {
        public enum Target: Codable, Sendable, Hashable {
            case url(URL)
            case tel(String)
            case maps
        }

        public var label: String
        public var target: Target

        public init(label: String, target: Target) {
            self.label = label
            self.target = target
        }
    }

    public struct Image: Codable, Sendable, Hashable {
        public var blobID: String?
        public var key: String?
        public var mime: String
        public var size: Int
        /// File name in the chat's attachment directory once downloaded.
        public var localFile: String?
    }

    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var detail: String?
        public var url: URL?
        public var latitude: Double?
        public var longitude: Double?
        public var actions: [Action]
        public var image: Image?

        public var hasLocation: Bool { latitude != nil && longitude != nil }
    }

    public var title: String
    public var kind: Kind
    public var items: [Item]

    public static let maxItems = 10

    /// The `presentation` object of a `chat` body; nil when unusable. Invalid parts are dropped.
    public static func parse(_ raw: JSON?) -> Presentation? {
        guard case .object(let object)? = raw, let title = text(object["title"], 120), !title.isEmpty,
              case .array(let rawItems)? = object["items"] else { return nil }
        let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)) ?? .list
        let items = rawItems.prefix(maxItems).enumerated().compactMap { index, raw in item(raw, id: index) }
        return items.isEmpty ? nil : Presentation(title: title, kind: kind, items: items)
    }

    private static func item(_ raw: JSON, id: Int) -> Item? {
        guard case .object(let object) = raw, let title = text(object["title"], 120), !title.isEmpty else { return nil }
        var latitude = number(object["lat"]), longitude = number(object["lon"])
        let located = latitude.map { (-90...90).contains($0) } == true && longitude.map { (-180...180).contains($0) } == true
        if !located {
            latitude = nil
            longitude = nil
        }
        var actions: [Action] = []
        if case .array(let rawActions)? = object["actions"] {
            for case .object(let action) in rawActions.prefix(3) {
                guard let label = text(action["label"], 30), !label.isEmpty else { continue }
                if let url = httpsURL(action["url"]) {
                    actions.append(Action(label: label, target: .url(url)))
                } else if let tel = action["tel"]?.string, isPhoneNumber(tel) {
                    actions.append(Action(label: label, target: .tel(tel)))
                } else if action["maps"]?.bool == true, latitude != nil {
                    actions.append(Action(label: label, target: .maps))
                }
            }
        }
        var image: Image?
        if case .object(let ref)? = object["image"], let blobID = ref["blob_id"]?.string, let key = ref["key"]?.string,
           (try? Base64URL.decode(key, length: 32)) != nil {
            image = Image(blobID: blobID, key: key, mime: "image/jpeg", size: Int(ref["size"]?.int ?? 0))
        }
        return Item(id: id, title: title, subtitle: text(object["subtitle"], 200), detail: text(object["detail"], 600),
                    url: httpsURL(object["url"]), latitude: latitude, longitude: longitude, actions: actions, image: image)
    }

    static func text(_ value: JSON?, _ limit: Int) -> String? {
        guard let string = value?.string else { return nil }
        let cleaned = String(string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }

    static func number(_ value: JSON?) -> Double? {
        switch value {
        case .double(let number)?: number.isFinite ? number : nil
        case .int(let number)?: Double(number)
        default: nil
        }
    }

    static func httpsURL(_ value: JSON?) -> URL? {
        guard let string = value?.string, string.count <= 1000, let url = URL(string: string),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil else { return nil }
        return url
    }

    static func isPhoneNumber(_ value: String) -> Bool {
        (3...30).contains(value.count) && value.allSatisfy { "+0123456789 -()/".contains($0) } && value.contains { $0.isNumber }
    }

    /// `tel:` with only the characters iOS dials.
    public static func telURL(_ number: String) -> URL? {
        URL(string: "tel:" + number.filter { "+0123456789".contains($0) })
    }
}
