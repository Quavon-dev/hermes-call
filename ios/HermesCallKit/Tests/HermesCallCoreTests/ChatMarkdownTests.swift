import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesCallCore

struct ChatMarkdownTests {
    @Test func paragraphsHeadingsAndRules() {
        let blocks = ChatMarkdown.blocks("# Plan ##\nFirst line\nsecond *line*\n\n---\n### Next")
        #expect(blocks == [.heading(level: 1, text: "Plan"), .paragraph("First line\nsecond *line*"), .rule,
                           .heading(level: 3, text: "Next")])
        #expect(ChatMarkdown.blocks("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func nestedOrderedAndTaskLists() {
        let blocks = ChatMarkdown.blocks("Steps:\n1. Build\n   continued\n2) Test\n  - [x] unit\n  - [ ] ui\n\n3. Ship\nAfter")
        #expect(blocks == [
            .paragraph("Steps:"),
            .list([
                MarkdownListItem(level: 0, number: 1, checked: nil, text: "Build\ncontinued"),
                MarkdownListItem(level: 0, number: 2, checked: nil, text: "Test"),
                MarkdownListItem(level: 1, number: nil, checked: true, text: "unit"),
                MarkdownListItem(level: 1, number: nil, checked: false, text: "ui"),
                MarkdownListItem(level: 0, number: 3, checked: nil, text: "Ship\nAfter"),
            ]),
        ])
    }

    @Test func codeFencesKeepTheirContent() {
        let blocks = ChatMarkdown.blocks("Run:\n```bash\n# not a heading\n| a | b |\n```\nDone\n~~~\nx\n")
        #expect(blocks == [.paragraph("Run:"), .code(language: "bash", text: "# not a heading\n| a | b |"), .paragraph("Done"),
                           .code(language: nil, text: "x\n")])
    }

    @Test func quotesNestBlocks() {
        #expect(ChatMarkdown.blocks("> **Note**\n> - one\n>\n> two") == [
            .quote([.paragraph("**Note**"), .list([MarkdownListItem(level: 0, number: nil, checked: nil, text: "one")]), .paragraph("two")]),
        ])
    }

    @Test func tablesWithAlignmentAndRaggedRows() {
        let blocks = ChatMarkdown.blocks("| City | Temp | Rain |\n|:---|---:|:-:|\n| Berlin | 21 | no |\n| Rome \\| IT | 28\n\nEnd")
        #expect(blocks == [
            .table(MarkdownTable(header: ["City", "Temp", "Rain"], alignments: [.leading, .trailing, .center],
                                 rows: [["Berlin", "21", "no"], ["Rome | IT", "28", ""]])),
            .paragraph("End"),
        ])
        // A pipe in prose is not a table.
        #expect(ChatMarkdown.blocks("a | b\nnext") == [.paragraph("a | b\nnext")])
    }

    @Test func photosAreShrunkToJPEG() throws {
        let context = try #require(CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let jpeg = try #require(PhotoEncoder.jpeg(png as Data))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 2048)
        #expect(PhotoEncoder.jpeg(Data("not an image".utf8)) == nil)
    }
}
