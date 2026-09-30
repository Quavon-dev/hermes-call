import HermesCallCore
import SwiftUI
import UIKit

/// Agent Markdown: headings, lists, code blocks, quotes, tables and rules (`ChatMarkdown`), with
/// inline styles and links inside each block.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = ChatMarkdown.blocks(markdown)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownText.attributed(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(MarkdownText.attributed(text))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 2 : 0)
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            MarkdownListView(items: items)
        case .code(let language, let text):
            CodeBlockView(language: language, text: text)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.6)).frame(width: 3) }
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

/// A code block: scrolls sideways with a fade at the edge that hides more (so it is clear there is more),
/// or wraps its lines (toggle); copy puts the whole block on the pasteboard.
private struct CodeBlockView: View {
    let language: String?
    let text: String
    @State private var wraps = false
    @State private var hiddenTrailing = false
    @State private var hiddenLeading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button { wraps.toggle() } label: {
                    Image(systemName: wraps ? "arrow.left.and.right" : "text.alignleft")
                }
                .accessibilityLabel(wraps ? "Scroll lines sideways" : "Wrap lines")
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy code")
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            if wraps {
                code.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: true) { code }
                    .onScrollGeometryChange(for: [Bool].self) { geometry in
                        [geometry.contentOffset.x > 1,
                         geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1]
                    } action: { _, edges in
                        hiddenLeading = edges[0]
                        hiddenTrailing = edges[1]
                    }
                    .mask(fade)
                    .overlay(alignment: .trailing) {
                        if hiddenTrailing {
                            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                                .padding(.trailing, 4).accessibilityHidden(true)
                        }
                    }
            }
        }
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private var code: some View {
        Text(text).font(.callout.monospaced()).textSelection(.enabled).padding(10)
    }

    /// Fades the edges that have more code behind them.
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [hiddenLeading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            Color.black
            LinearGradient(colors: [.black, hiddenTrailing ? .clear : .black], startPoint: .leading, endPoint: .trailing).frame(width: 36)
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item).frame(minWidth: 16, alignment: .trailing)
                    Text(MarkdownText.attributed(item.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square").font(.footnote)
                .accessibilityLabel(checked ? "done" : "open")
        } else if let number = item.number {
            Text("\(number).").monospacedDigit()
        } else {
            Text(item.level == 0 ? "•" : "◦")
        }
    }
}

/// A table stays a table: a grid that scrolls sideways when wider than the bubble.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellText(cell, column: column).font(.subheadline.bold())
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellText(cell, column: column).font(.subheadline)
                        }
                    }
                    if index < table.rows.count - 1 {
                        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(10)
        }
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cellText(_ text: String, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(MarkdownText.attributed(text))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: 220, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
