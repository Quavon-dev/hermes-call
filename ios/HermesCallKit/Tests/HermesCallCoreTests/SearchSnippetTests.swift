// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

struct SearchSnippetTests {
    func message(_ text: String, files: [String] = []) -> ChatMessage {
        ChatMessage(id: "m", role: .owner, text: text,
                    attachments: files.map { ChatAttachment(kind: .file, name: $0, mime: "application/pdf", size: 10) }, status: .delivered)
    }

    func matched(_ snippet: SearchSnippet) -> String? {
        snippet.match.map { String(snippet.text[$0]) }
    }

    @Test func textMatchIsMarked() {
        let snippet = SearchSnippet(message: message("Please pay the invoice today"), query: "INVOICE")
        #expect(matched(snippet) == "invoice")
    }

    /// A hit in an attachment's file name is shown and marked like a text hit.
    @Test func attachmentNameMatchIsMarked() {
        let snippet = SearchSnippet(message: message("Here you go", files: ["Hetzner-Rechnung-2026.pdf"]), query: "rechnung")
        #expect(matched(snippet) == "Rechnung")
        #expect(snippet.text.contains("Hetzner-Rechnung-2026.pdf"))
    }

    @Test func accentsAreIgnored() {
        let snippet = SearchSnippet(message: message("Lunch at the café"), query: "cafe")
        #expect(matched(snippet) == "café")
    }

    @Test func longTextStartsShortlyBeforeTheMatch() {
        let long = String(repeating: "word ", count: 60) + "needle and more"
        let snippet = SearchSnippet(message: message(long), query: "needle")
        #expect(snippet.text.hasPrefix("…"))
        #expect(matched(snippet) == "needle")
    }

    @Test func noMatchShowsThePreview() {
        let snippet = SearchSnippet(message: message("Hello there"), query: "zzz")
        #expect(snippet.match == nil)
        #expect(snippet.text == "Hello there")
    }
}
