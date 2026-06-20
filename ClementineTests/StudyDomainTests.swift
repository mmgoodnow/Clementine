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

    func testAdaptivePolicyStillIntroducesSomeNewCardsAfterLowAccuracyWhenLoadAllows() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<30).map { index in
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

        XCTAssertFalse(decision.orderedCards.isEmpty)
        XCTAssertLessThan(decision.orderedCards.count, newCards.count)
    }

    func testLearningPaceControlsReviewLoadBudget() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<40).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let low = AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .low, recentAccuracy: 0.9, now: now).orderedCards.count
        let balanced = AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .balanced, recentAccuracy: 0.9, now: now).orderedCards.count
        let high = AdaptiveSessionPolicy.chooseCards(from: newCards, pace: .high, recentAccuracy: 0.9, now: now).orderedCards.count

        XCTAssertLessThan(low, balanced)
        XCTAssertLessThan(balanced, high)
    }

    func testLowerAccuracyReducesButDoesNotZeroNewCardAllowance() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<30).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let highAccuracy = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        ).orderedCards.count
        let lowAccuracy = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.45,
            now: now
        ).orderedCards.count

        XCTAssertGreaterThan(lowAccuracy, 0)
        XCTAssertLessThan(lowAccuracy, highAccuracy)
    }

    func testForecastedReviewLoadReducesNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<35).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<30).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let withoutBacklog = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        ).orderedCards.count
        let withBacklog = AdaptiveSessionPolicy.chooseCards(
            from: futureReviews + newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        ).orderedCards.filter(\.isNew).count

        XCTAssertLessThan(withBacklog, withoutBacklog)
    }

    func testForcedContinueIntroducesNewCardsDespiteLowAccuracy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<18).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCard = SessionCardCandidate(id: UUID(), dueAt: now, isNew: true, recentLapses: 0)

        XCTAssertTrue(
            AdaptiveSessionPolicy.chooseCards(from: futureReviews + [newCard], pace: .low, recentAccuracy: 0.2, now: now).orderedCards.isEmpty
        )
        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(
                from: futureReviews + [newCard],
                pace: .low,
                recentAccuracy: 0.2,
                now: now,
                forceNewCards: true
            ).orderedCards.filter(\.isNew),
            [newCard]
        )
    }
}
