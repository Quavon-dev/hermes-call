import Foundation
import Testing
@testable import HermesCallCore

/// `hermescall://` links: any app or web page can open them, so only the app's own widget (which knows
/// the per-install secret) may start a call or switch the agent without asking.
@Suite struct DeepLinkTests {
    let secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t-a"
    let agent = UUID()

    func parse(_ text: String, secret: String? = nil) -> DeepLink? {
        DeepLink.parse(URL(string: text)!, secret: secret ?? self.secret)
    }

    @Test func externalCallLinksMustBeConfirmed() {
        #expect(parse("hermescall://call") == .call(agent: nil, trusted: false))
        #expect(parse("hermescall://call?agent=\(agent.uuidString)") == .call(agent: agent, trusted: false))
        #expect(parse("hermescall://call?agent=\(agent.uuidString)&s=wrong") == .call(agent: agent, trusted: false))
        #expect(parse("hermescall://call?s=") == .call(agent: nil, trusted: false))
    }

    @Test func theWidgetsOwnLinksAreTrusted() throws {
        let link = try #require(LinkSecret.link("call", agent: agent, secret: secret))
        #expect(DeepLink.parse(link, secret: secret) == .call(agent: agent, trusted: true))
        #expect(DeepLink.parse(link, secret: "another install") == .call(agent: agent, trusted: false))
        #expect(DeepLink.parse(link, secret: nil) == .call(agent: agent, trusted: false))
    }

    @Test func externalChatLinksDoNotSwitchTheAgent() throws {
        #expect(parse("hermescall://chat?agent=\(agent.uuidString)") == .chat(agent: nil))
        let own = try #require(LinkSecret.link("chat", agent: agent, secret: secret))
        #expect(DeepLink.parse(own, secret: secret) == .chat(agent: agent))
    }

    @Test func otherLinks() {
        #expect(parse("hermescall://pair?v=1&k=device&r=a.example&c=ABC12345") == .pair("hermescall://pair?v=1&k=device&r=a.example&c=ABC12345"))
        #expect(parse("hermescall://open") == .open)
        #expect(parse("hermescall://evil") == nil)
        #expect(parse("https://call?agent=\(agent.uuidString)") == nil)
        #expect(parse("hermescall://call?agent=not-a-uuid") == .call(agent: nil, trusted: false))
    }

    @Test func secretIsCreatedOnceAndIsLongAndRandom() throws {
        let defaults = try #require(UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)"))
        #expect(LinkSecret.current(defaults) == nil)
        let first = LinkSecret.ensure(defaults)
        #expect(LinkSecret.ensure(defaults) == first && LinkSecret.current(defaults) == first)
        #expect(try Base64URL.decode(first).count == 32)
        let other = try #require(UserDefaults(suiteName: "hermescall.tests.\(UUID().uuidString)"))
        #expect(LinkSecret.ensure(other) != first)
    }

    @Test func secretComparison() {
        #expect(LinkSecret.matches(secret, secret))
        #expect(!LinkSecret.matches(String(secret.dropLast()), secret))
        #expect(!LinkSecret.matches(nil, secret) && !LinkSecret.matches(secret, nil) && !LinkSecret.matches("", ""))
    }
}
