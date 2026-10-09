import UIKit
import XCTest

/// App Store screenshots on the demo agent (6.9": run on an iPhone 17 Pro Max simulator). Skipped unless
/// `TEST_RUNNER_APPSTORE_SHOTS=<folder>` is set for xcodebuild; PNGs go to that folder.
@MainActor
final class AppStoreScreenshots: XCTestCase {
    private var app: XCUIApplication!
    private var folder = ""

    override func setUp() async throws {
        guard let folder = ProcessInfo.processInfo.environment["APPSTORE_SHOTS"] else {
            throw XCTSkip("App Store screenshots only on request")
        }
        self.folder = folder
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testHUDPresenceAndCall() throws {
        app.launchArguments = ["-UITestReset", "YES", "-UITestConsent", "YES", "-appearance", "hud"]
        app.launch()
        startDemo()
        let presence = app.descendants(matching: .any)["presence"].firstMatch
        XCTAssertTrue(presence.waitForExistence(timeout: 8))
        sleep(3)
        save("1-presence")
        presence.tap()
        XCTAssertTrue(app.buttons["End call"].firstMatch.waitForExistence(timeout: 5))
        sleep(10)
        save("2-call")
        app.buttons["End call"].firstMatch.tap()
    }

    func testChatCardsAndPhoneAccess() throws {
        app.launchArguments = ["-UITestReset", "YES", "-UITestConsent", "YES", "-appearance", "standard"]
        app.launch()
        startDemo()
        send("Plan my day")
        XCTAssertTrue(app.staticTexts["Your day"].waitForExistence(timeout: 10))
        send("Any quiet places for dinner nearby?")
        XCTAssertTrue(app.staticTexts["Linden Reading Café"].firstMatch.waitForExistence(timeout: 10))
        // Again without the keyboard: the chat is kept (the demo agent and its history stay until removed).
        app.terminate()
        app.launchArguments = ["-appearance", "standard"]
        app.launch()
        let place = app.staticTexts["Linden Reading Café"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 10))
        drag(from: 0.3, to: 0.75)
        sleep(2)
        save("3-chat")
        // The cards moment: one place opened, with its map, over the conversation.
        drag(from: 0.75, to: 0.3)
        sleep(1)
        place.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Directions' OR label CONTAINS 'Call'")).firstMatch
            .waitForExistence(timeout: 5) || app.maps.firstMatch.waitForExistence(timeout: 5))
        sleep(4)
        save("4-cards")
        // Phone access: the agent asks, the owner decides (the Ask rule).
        app.terminate()
        app.launchArguments = ["-appearance", "standard", "-PhoneDemoPrompt", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'asks for'")).firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("5-phone-access")
    }

    /// A finger drag over the middle of the screen (y as a share of its height).
    private func drag(from start: Double, to end: Double) {
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
        origin.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
    }

    private func startDemo() {
        for _ in 0..<3 { app.buttons["onboarding.continue"].firstMatch.tap() }
        app.buttons["onboarding.demo"].firstMatch.tap()
    }

    private func send(_ text: String) {
        let field = app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        app.buttons["Send"].firstMatch.tap()
    }

    /// One line above the device area per shot.
    static let captions = [
        "1-presence": "Your agent, always there",
        "2-call": "Call it like a person",
        "3-chat": "Encrypted chat, rich replies",
        "4-cards": "Plans and places, mapped",
        "5-phone-access": "It asks. You decide.",
    ]

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let page = Self.captions[name].flatMap { Self.captioned(shot.image, caption: $0) } ?? shot.pngRepresentation
        try? page.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The App Store page: the caption on the app's near-black backdrop, the screen below it with rounded
    /// corners, at the screenshot's own size (6.9": 1320 × 2868).
    static func captioned(_ screen: UIImage, caption: String) -> Data? {
        guard let cgImage = screen.cgImage else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let deep = UIColor(red: 0.03, green: 0.024, blue: 0.02, alpha: 1)
        let light = UIColor(red: 1.0, green: 0.91, blue: 0.69, alpha: 1)
        let band = size.height * 0.15
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            deep.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let font = UIFont.systemFont(ofSize: size.width * 0.064, weight: .bold)
            let text = NSAttributedString(string: caption, attributes: [.font: font, .foregroundColor: light, .paragraphStyle: style])
            let textBox = CGRect(x: size.width * 0.07, y: 0, width: size.width * 0.86, height: band)
            let bounds = text.boundingRect(with: textBox.size, options: [.usesLineFragmentOrigin], context: nil)
            text.draw(with: CGRect(x: textBox.minX, y: band * 0.58 - bounds.height / 2, width: textBox.width, height: bounds.height),
                      options: [.usesLineFragmentOrigin], context: nil)
            let scale = (size.height - band - size.height * 0.02) / size.height
            let device = CGRect(x: (size.width - size.width * scale) / 2, y: band, width: size.width * scale, height: size.height * scale)
            UIBezierPath(roundedRect: device, cornerRadius: device.width * 0.09).addClip()
            UIImage(cgImage: cgImage).draw(in: device)
        }
    }
}
