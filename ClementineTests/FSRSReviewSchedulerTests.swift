@testable import Clementine
import XCTest

final class FSRSReviewSchedulerTests: XCTestCase {
    func testReviewProducesPersistableNextState() throws {
        let now = Date(timeIntervalSince1970: 1_000)

        let result = try FSRSReviewScheduler.review(cardData: nil, grade: .good, now: now)

        XCTAssertFalse(result.cardData.isEmpty)
        XCTAssertGreaterThanOrEqual(result.dueAt.timeIntervalSince1970, now.timeIntervalSince1970)
        XCTAssertGreaterThanOrEqual(result.scheduledDays, 0)
        XCTAssertFalse(result.state.isEmpty)
    }
}
