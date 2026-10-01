import XCTest

/// End-to-end flows on the offline demo agent (no relay needed): onboarding → demo → consent → chat →
/// call → settings. Launch arguments make every run start like a fresh install.
/// `SCREENSHOT_DIR` (environment of the test run, e.g. `TEST_RUNNER_SCREENSHOT_DIR`) saves a PNG per step.
@MainActor
final class HermesCallUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "YES", "-appearance", "standard"]
    }

    func testOnboardingDemoChatAndCall() throws {
        app.launch()
        for page in 1...3 {
            snap("onboarding-\(page)")
            tap("onboarding.continue")
        }
        snap("onboarding-4")
        tap("onboarding.demo")
        XCTAssertTrue(app.buttons["consent.allow"].waitForExistence(timeout: 5))
        snap("consent")
        tap("consent.allow")

        app.tabBars.buttons["Chat"].tap()
        let field = app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Plan my day")
        app.buttons["Send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your day"].waitForExistence(timeout: 10), "the demo agent answers")
        snap("demo-chat")

        // The chat's call button (the keyboard covers the tab bar).
        app.navigationBars.buttons["Call"].firstMatch.tap()
        let hangUp = app.buttons["call.hangUp"]
        XCTAssertTrue(hangUp.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Atlas"].exists)
        sleep(7)
        snap("demo-call")
        hangUp.tap()
        XCTAssertFalse(hangUp.waitForExistence(timeout: 3), "the call screen closes")
        XCTAssertTrue(app.staticTexts["Outgoing call"].firstMatch.waitForExistence(timeout: 5) || app.textFields["Message"].exists)
    }

    func testPresenceTapStartsTheDemoCall() throws {
        app.launchArguments = ["-UITestReset", "YES", "-UITestConsent", "YES", "-appearance", "hud"]
        app.launch()
        for _ in 0..<3 { tap("onboarding.continue") }
        tap("onboarding.demo")
        let presence = app.buttons["presence"].firstMatch.exists ? app.buttons["presence"].firstMatch : app.otherElements["presence"].firstMatch
        XCTAssertTrue(presence.waitForExistence(timeout: 8))
        sleep(2)
        snap("presence-home")
        presence.tap()
        let end = app.buttons["End call"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        // Speaker and mute sit next to End, not only in the long-press menu.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Speaker'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Microphone'")).firstMatch.exists)
        sleep(8)
        snap("presence-call")
        end.tap()
        XCTAssertFalse(end.waitForExistence(timeout: 2))
    }

    /// The emergency stop: a red Stop next to the call button while the agent works; the demo reply never comes.
    func testStopFromTheChat() throws {
        app.launchArguments += ["-UITestConsent", "YES", "-DemoThinkingSeconds", "8"]
        app.launch()
        for _ in 0..<3 { tap("onboarding.continue") }
        tap("onboarding.demo")
        app.tabBars.buttons["Chat"].tap()
        let field = app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.stop"].exists, "no Stop while the agent is idle")
        field.tap()
        field.typeText("Plan my day")
        app.buttons["Send"].firstMatch.tap()
        let stop = app.buttons["chat.stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop shows while the agent types")
        snap("chat-stop")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.stopRequested"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '⚡ Stopped'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5), "Stop goes once the agent answered")
        snap("chat-stopped")
        XCTAssertFalse(app.staticTexts["Your day"].waitForExistence(timeout: 9), "the stopped reply never comes")
    }

    /// The presence's menu offers Stop.
    func testPresenceMenuOffersStop() throws {
        app.launchArguments = ["-UITestReset", "YES", "-UITestConsent", "YES", "-appearance", "hud"]
        app.launch()
        for _ in 0..<3 { tap("onboarding.continue") }
        tap("onboarding.demo")
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        sleep(2)
        more.tap()
        let stop = app.buttons["Stop agent"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        sleep(1)
        snap("presence-menu-stop")
        stop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["presence.stopRequested"].firstMatch.waitForExistence(timeout: 3))
        snap("presence-stop-requested")
    }

    func testSettingsAndDiagnostics() throws {
        app.launchArguments += ["-UITestConsent", "YES"]
        app.launch()
        for _ in 0..<3 { tap("onboarding.continue") }
        tap("onboarding.demo")
        tap("home.settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snap("settings")
        XCTAssertTrue(app.switches["settings.consent"].exists || app.swipeUpUntil("settings.consent"))
        app.swipeUpUntil("settings.diagnostics")
        tap("settings.diagnostics")
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
        snap("diagnostics")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.collectionViews.firstMatch.swipeDown()
        app.collectionViews.firstMatch.swipeDown()
        tap("agent.Atlas")
        tap("demo.remove")
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 8), "removing the demo returns to onboarding")
    }

    func testPairingExplainsWhatIsWrong() throws {
        app.launch()
        for _ in 0..<3 { tap("onboarding.continue") }
        tap("onboarding.addRelay")
        let address = app.textFields["pair.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("relay.example.com")
        let code = app.textFields["Code, e.g. K7Q-4TXP9"]
        code.tap()
        code.typeText("12")
        app.navigationBars["Add relay"].buttons["Pair"].tap()
        let error = app.descendants(matching: .any)["pair.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        snap("pairing-error")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '8-character code'")).firstMatch.exists)
    }

    /// Two paired agents: the chat tab lists both (newest first, unread per agent), opens one, and back.
    func testInboxListsEveryAgent() throws {
        app.launchArguments += ["-UITestConsent", "YES", "-UITestAgents", "YES"]
        app.launch()
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 8))
        let nova = app.buttons["inbox.Nova"].firstMatch
        XCTAssertTrue(nova.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["inbox.Iris"].exists)
        XCTAssertTrue(nova.label.contains("2 unread"), "Nova's unread count: \(nova.label)")
        XCTAssertLessThan(nova.frame.minY, app.buttons["inbox.Iris"].frame.minY, "the newest conversation comes first")
        snap("inbox")
        nova.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'gate B12'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Message"].exists)
        snap("inbox-chat")
        app.navigationBars.buttons["Chats"].firstMatch.tap()
        XCTAssertTrue(nova.waitForExistence(timeout: 5))
        XCTAssertFalse(nova.label.contains("unread"), "reading the chat clears its count: \(nova.label)")
    }

    /// A `hermescall://call` link from outside (another app, a web page) asks before the microphone goes live.
    func testOutsideCallLinkAsksFirst() throws {
        app.launchArguments += ["-UITestConsent", "YES", "-UITestAgents", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Call"].waitForExistence(timeout: 8))
        app.open(URL(string: "hermescall://call")!)
        // iOS may ask "Open in Hermes Call?" for a link from outside.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        let title = app.staticTexts["callLink.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "an outside call link must ask first")
        XCTAssertTrue(title.label.hasPrefix("Call "), title.label)
        XCTAssertTrue(app.buttons["callLink.call"].exists)
        let notNow = springboard.buttons["Don’t Allow"]  // the notification permission alert, if it is up
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        snap("call-link-confirm")
        app.buttons["callLink.cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["End"].exists, "Cancel starts no call")
    }

    // MARK: helpers

    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(identifier) missing", file: file, line: line)
        element.tap()
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

extension XCUIApplication {
    /// Scrolls the first list up until the element with `identifier` is on screen.
    @discardableResult
    func swipeUpUntil(_ identifier: String, attempts: Int = 5) -> Bool {
        let element = descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<attempts where !(element.exists && element.isHittable) {
            collectionViews.firstMatch.swipeUp()
        }
        return element.exists
    }
}
