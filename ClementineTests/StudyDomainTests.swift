@testable import Clementine
import XCTest

final class StudyDomainTests: XCTestCase {
    func testMultipleChoiceGradeMapping() {
        XCTAssertEqual(ReviewGradeMapper.multipleChoice(correct: false, responseSeconds: 1), .again)
        XCTAssertEqual(ReviewGradeMapper.multipleChoice(correct: true, responseSeconds: 9), .hard)
        XCTAssertEqual(ReviewGradeMapper.multipleChoice(correct: true, responseSeconds: 4), .good)
        XCTAssertEqual(ReviewGradeMapper.multipleChoice(correct: true, responseSeconds: 2), .easy)
    }

    func testRecallGradeMapping() {
        XCTAssertEqual(ReviewGradeMapper.recall(remembered: false, confident: false), .again)
        XCTAssertEqual(ReviewGradeMapper.recall(remembered: true, confident: false), .hard)
        XCTAssertEqual(ReviewGradeMapper.recall(remembered: true, confident: true), .good)
    }

    func testAdaptivePolicyPrefersDueReviews() {
        let now = Date(timeIntervalSince1970: 1_000)
        let due = SessionCardCandidate(id: UUID(), dueAt: now.addingTimeInterval(-60), isNew: false, recentLapses: 0)
        let new = SessionCardCandidate(id: UUID(), dueAt: now, isNew: true, recentLapses: 0)

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: [new, due],
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertEqual(decision.orderedCards.first, due)
        XCTAssertFalse(decision.shouldStopNaturally)
    }

    func testAdaptivePolicyStopsWhenNothingUsefulIsAvailable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = SessionCardCandidate(id: UUID(), dueAt: now.addingTimeInterval(60), isNew: false, recentLapses: 0)

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: [future],
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertTrue(decision.orderedCards.isEmpty)
        XCTAssertTrue(decision.shouldStopNaturally)
    }

    func testAdaptivePolicySuppressesNewCardsAfterLowAccuracy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<5).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .high,
            recentAccuracy: 0.5,
            now: now
        )

        XCTAssertTrue(decision.orderedCards.isEmpty)
    }

    func testLearningPaceControlsNewCardAllowance() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<12).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .low, recentAccuracy: 0.9, now: now).orderedCards.count,
            2
        )
        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .balanced, recentAccuracy: 0.9, now: now).orderedCards.count,
            5
        )
        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .high, recentAccuracy: 0.9, now: now).orderedCards.count,
            9
        )
    }
}
