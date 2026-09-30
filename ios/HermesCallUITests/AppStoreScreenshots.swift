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
        app.tabBars.buttons["Chat"].tap()
        send("Plan my day")
        XCTAssertTrue(app.staticTexts["Your day"].waitForExistence(timeout: 10))
        send("Any quiet places for dinner nearby?")
        XCTAssertTrue(app.staticTexts["Linden Reading Café"].firstMatch.waitForExistence(timeout: 10))
        // Again without the keyboard: the chat is kept (the demo agent and its history stay until removed).
        app.terminate()
        app.launchArguments = ["-appearance", "standard"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.staticTexts["Linden Reading Café"].firstMatch.waitForExistence(timeout: 10))
        sleep(4)
        save("4-cards")
        drag(from: 0.3, to: 0.75)
        sleep(1)
        save("3-chat")
        app.tabBars.buttons["Call"].tap()
        let settings = app.descendants(matching: .any)["home.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.swipeUpUntil("Phone access")
        app.buttons["Phone access"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Phone access"].waitForExistence(timeout: 5))
        sleep(1)
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

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
