import XCTest

/// Needs a signed-in Gannin with a project, as `scripts/relaunch.sh` leaves it.
/// A labelled field in a grouped Form puts its text on the right, where a trailing
/// space hangs past the edge and doesn't show. The width assertion catches that
/// layout coming back; the screenshot is attached for a person to look at.
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
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(field.frame.width, window.width * 0.5, "field is \(field.frame) in a window \(window)")
    }
}
