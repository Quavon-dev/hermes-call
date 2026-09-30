// SPDX-License-Identifier: MIT
import Foundation

/// What a search hit shows: the part of the message around the match (text, transcript, file names or card
/// titles, whichever matched first), starting shortly before it, with the match's range to mark.
public struct SearchSnippet: Sendable {
    public let text: String
    public let match: Range<String.Index>?

    static let before = 40
    static let after = 120

    public init(message: ChatMessage, query: String) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        for part in Self.parts(of: message) where !needle.isEmpty {
            let plain = ChatText.plain(part, limit: 2000)
            guard let range = plain.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = plain.index(range.lowerBound, offsetBy: -Self.before, limitedBy: plain.startIndex) ?? plain.startIndex
            let end = plain.index(range.upperBound, offsetBy: Self.after, limitedBy: plain.endIndex) ?? plain.endIndex
            let prefix = start > plain.startIndex ? "…" : ""
            let text = prefix + plain[start..<end]
            let lower = text.index(text.startIndex, offsetBy: prefix.count + plain.distance(from: start, to: range.lowerBound))
            let upper = text.index(lower, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            self.text = text
            match = lower..<upper
            return
        }
        let fallback = message.role == .system ? message.systemText : ChatText.plain(message.preview, limit: 2000)
        text = String(fallback.prefix(160))
        match = nil
    }

    /// Where a query can match, in the order a hit is shown.
    static func parts(of message: ChatMessage) -> [String] {
        var parts = [message.role == .system ? message.systemText : message.text, message.transcript ?? ""]
        parts += message.attachments.map { "📎 \($0.name)" }
        if let presentation = message.presentation {
            parts.append(presentation.title)
            parts += presentation.items.flatMap { [$0.title, $0.subtitle ?? "", $0.detail ?? ""] }
        }
        return parts.filter { !$0.isEmpty }
    }
}
