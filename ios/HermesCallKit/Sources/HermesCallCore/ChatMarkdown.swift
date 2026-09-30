import Foundation

/// Block-level Markdown for agent messages (headings, lists, code, quotes, tables, rules). Inline
/// styles inside each block are left to `AttributedString(markdown:)`; no HTML, no web view.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting depth, 0 for the outermost items.
    public var level: Int
    /// The number of an ordered item ("3." → 3), nil for bullets.
    public var number: Int?
    /// Task lists: `[x]` true, `[ ]` false.
    public var checked: Bool?
    public var text: String
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    /// Every row has as many cells as the header.
    public var rows: [[String]]
}

public enum ChatMarkdown {
    /// Longer messages are not parsed further (the rest shows as one paragraph).
    static let maxLines = 2000

    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count > maxLines {
            let rest = lines[maxLines...].joined(separator: "\n")
            lines = Array(lines[..<maxLines]) + [rest]
        }
        var parser = Parser(lines: lines)
        return parser.parse()
    }

    private struct Parser {
        let lines: [String]
        var index = 0

        mutating func parse() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                } else if let fence = Self.fence(line) {
                    blocks.append(code(fence))
                } else if let heading = Self.heading(line) {
                    blocks.append(heading)
                    index += 1
                } else if Self.isRule(line) {
                    blocks.append(.rule)
                    index += 1
                } else if Self.quoteContent(line) != nil {
                    blocks.append(quote())
                } else if Self.listItem(line) != nil {
                    blocks.append(list())
                } else if let table = table() {
                    blocks.append(.table(table))
                } else {
                    blocks.append(paragraph())
                }
            }
            return blocks
        }

        /// A line that starts some other block ends a paragraph.
        private func startsBlock(_ line: String, at position: Int) -> Bool {
            Self.fence(line) != nil || Self.heading(line) != nil || Self.isRule(line) || Self.quoteContent(line) != nil
                || Self.listItem(line) != nil || (position + 1 < lines.count && Self.isTableStart(line, lines[position + 1]))
        }

        private mutating func paragraph() -> MarkdownBlock {
            var text: [String] = [lines[index]]
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(lines[index], at: index) {
                text.append(lines[index])
                index += 1
            }
            return .paragraph(text.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
        }

        private mutating func code(_ fence: (marker: String, language: String?)) -> MarkdownBlock {
            index += 1
            var body: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
                if trimmed.hasPrefix(fence.marker), trimmed.allSatisfy({ $0 == fence.marker.first }) { break }
                body.append(lines[index - 1])
            }
            return .code(language: fence.language, text: body.joined(separator: "\n"))
        }

        private mutating func quote() -> MarkdownBlock {
            var inner: [String] = []
            while index < lines.count, let content = Self.quoteContent(lines[index]) {
                inner.append(content)
                index += 1
            }
            var nested = Parser(lines: inner)
            return .quote(nested.parse())
        }

        private mutating func list() -> MarkdownBlock {
            var items: [MarkdownListItem] = []
            while index < lines.count {
                let line = lines[index]
                if let item = Self.listItem(line) {
                    items.append(item)
                    index += 1
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line continues the list only when another item follows.
                    guard index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil else { break }
                    index += 1
                } else if line.hasPrefix(" ") || line.hasPrefix("\t"), !items.isEmpty, !startsBlock(line, at: index) {
                    items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                    index += 1
                } else if !items.isEmpty, !startsBlock(line, at: index) {
                    // Lazy continuation of the last item.
                    items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                    index += 1
                } else {
                    break
                }
            }
            return .list(items)
        }

        private mutating func table() -> MarkdownTable? {
            guard index + 1 < lines.count, Self.isTableStart(lines[index], lines[index + 1]) else { return nil }
            let header = Self.cells(lines[index])
            let alignments = Self.cells(lines[index + 1]).map { cell -> MarkdownTable.Alignment in
                switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
                case (true, true): .center
                case (false, true): .trailing
                default: .leading
                }
            }
            index += 2
            var rows: [[String]] = []
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let cells = Self.cells(lines[index])
                rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
                index += 1
            }
            let columns = header.count
            return MarkdownTable(header: header, alignments: (0..<columns).map { $0 < alignments.count ? alignments[$0] : .leading },
                                 rows: rows)
        }

        // MARK: line tests

        static func fence(_ line: String) -> (marker: String, language: String?)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
                let info = trimmed.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
                let run = String(trimmed.prefix { $0 == marker.first })
                return (run, info.isEmpty ? nil : String(info.prefix { !$0.isWhitespace }))
            }
            return nil
        }

        static func heading(_ line: String) -> MarkdownBlock? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
        }

        static func isRule(_ line: String) -> Bool {
            let compact = line.filter { !$0.isWhitespace }
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        static func quoteContent(_ line: String) -> String? {
            let trimmed = line.drop { $0 == " " }
            guard trimmed.first == ">" else { return nil }
            let content = trimmed.dropFirst()
            return String(content.first == " " ? content.dropFirst() : content)
        }

        static func listItem(_ line: String) -> MarkdownListItem? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let rest = line.drop { $0 == " " || $0 == "\t" }
            var number: Int?
            var body: Substring
            if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
                body = rest.dropFirst(2)
            } else {
                let digits = rest.prefix { $0.isNumber }
                guard (1...9).contains(digits.count), let value = Int(digits) else { return nil }
                let after = rest.dropFirst(digits.count)
                guard let delimiter = after.first, ".)".contains(delimiter), after.dropFirst().first == " " else { return nil }
                number = value
                body = after.dropFirst(2)
            }
            var checked: Bool?
            if body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                checked = body.dropFirst().first != " "
                body = body.dropFirst(4)
            }
            return MarkdownListItem(level: min(indent / 2, 4), number: number, checked: checked,
                                    text: body.trimmingCharacters(in: .whitespaces))
        }

        static func isTableStart(_ line: String, _ next: String) -> Bool {
            guard line.contains("|") else { return false }
            let delimiters = cells(next)
            guard !delimiters.isEmpty, delimiters.count == cells(line).count || next.contains("|") else { return false }
            return delimiters.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !core.isEmpty && core.allSatisfy { $0 == "-" }
            }
        }

        /// Cells of a table row: split on `|` (not `\|`), outer pipes optional.
        static func cells(_ line: String) -> [String] {
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in line.trimmingCharacters(in: .whitespaces) {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "|" {
                    cells.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            cells.append(current)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
            if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                cells.removeLast()
            }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
