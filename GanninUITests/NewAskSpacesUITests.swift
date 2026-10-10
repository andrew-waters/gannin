import XCTest

/// Needs a signed-in Gannin with a project, as `scripts/relaunch.sh` leaves it.
/// The value assertion guards against the text being trimmed as it's typed; where
/// the caret sits after a trailing space isn't visible to XCTest, so the
/// screenshot is attached for a person to look at.
final class NewAskSpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSpacesTypedInNewAskAreKept() {
        let app = XCUIApplication()
        app.launch()

        let newAsk = app.buttons["New Ask"].firstMatch
        XCTAssertTrue(newAsk.waitForExistence(timeout: 30), "No New Ask button: is Gannin signed in with a project?")
        newAsk.click()

        let field = app.descendants(matching: .any)["ask-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeText("a   b ")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertEqual(field.value as? String, "a   b ")
    }
}
