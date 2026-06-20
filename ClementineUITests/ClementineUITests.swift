import XCTest

final class ClementineUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStudySurfaceLoads() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["study.start"].waitForExistence(timeout: 5))
    }
}
