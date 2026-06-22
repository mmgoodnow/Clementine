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

    func testMultipleChoiceDistractorsUseWholePoolBeforeTruncating() {
        let choices = MultipleChoiceBuilder.choices(
            correctAnswer: "zhōng guó",
            distractorPool: ["èr", "èr zi", "bù", "bà ba", "lǎo shī", "xué sheng", "míng tiān"],
            seed: "hsk2-9999#hanziToPinyin"
        )

        XCTAssertTrue(choices.contains("zhōng guó"))
        XCTAssertNotEqual(Set(choices.filter { $0 != "zhōng guó" }), Set(["èr", "èr zi", "bù"]))
    }

    func testPinyinDistractorsPreferMatchingSyllableCount() {
        let correct = "zhōng guó"
        let choices = MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: ["èr", "bù", "wǒ", "bà ba", "lǎo shī", "xué sheng", "míng tiān"],
            seed: "hsk2-9999#hanziToPinyin",
            preferredSyllableCount: MultipleChoiceBuilder.pinyinSyllableCount(correct)
        )

        XCTAssertEqual(choices.count, 4)
        XCTAssertTrue(choices.contains(correct))
        XCTAssertTrue(
            choices
                .filter { $0 != correct }
                .allSatisfy { MultipleChoiceBuilder.pinyinSyllableCount($0) == 2 }
        )
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

    func testNextCandidateAvoidsRecentlyShownCardWhenAlternativeExists() {
        let now = Date(timeIntervalSince1970: 1_000)
        let repeated = SessionCardCandidate(
            id: UUID(),
            dueAt: now,
            isNew: false,
            recentLapses: 1,
            noteSourceID: "word-1",
            kind: .hanziToMeaning
        )
        let alternative = SessionCardCandidate(
            id: UUID(),
            dueAt: now,
            isNew: false,
            recentLapses: 0,
            noteSourceID: "word-2",
            kind: .hanziToPinyin
        )

        XCTAssertEqual(
            AdaptiveSessionPolicy.nextCandidate(
                from: [repeated, alternative],
                recentCardIDs: [repeated.id],
                recentNoteSourceIDs: []
            ),
            alternative
        )
    }

    func testNextCandidateAvoidsRecentlyShownVocabularyWhenAlternativeExists() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sibling = SessionCardCandidate(
            id: UUID(),
            dueAt: now,
            isNew: true,
            recentLapses: 0,
            noteSourceID: "word-1",
            kind: .hanziToPinyin
        )
        let alternative = SessionCardCandidate(
            id: UUID(),
            dueAt: now,
            isNew: true,
            recentLapses: 0,
            noteSourceID: "word-2",
            kind: .hanziToMeaning
        )

        XCTAssertEqual(
            AdaptiveSessionPolicy.nextCandidate(
                from: [sibling, alternative],
                recentCardIDs: [],
                recentNoteSourceIDs: ["word-1"]
            ),
            alternative
        )
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
            pace: .balanced,
            recentAccuracy: 0.5,
            now: now
        )

        XCTAssertFalse(decision.orderedCards.isEmpty)
        XCTAssertLessThan(decision.orderedCards.count, newCards.count)
    }

    func testLearningPaceControlsReviewLoadBudget() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<90).map { index in
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

    func testLearningPaceControlsHiddenDesiredRetention() {
        let low = AdaptiveSessionPolicy.desiredRetention(
            pace: .low,
            forecastedReviewLoad: 6,
            recentAccuracy: 0.9
        )
        let balanced = AdaptiveSessionPolicy.desiredRetention(
            pace: .balanced,
            forecastedReviewLoad: 6,
            recentAccuracy: 0.9
        )
        let high = AdaptiveSessionPolicy.desiredRetention(
            pace: .high,
            forecastedReviewLoad: 6,
            recentAccuracy: 0.9
        )

        XCTAssertLessThan(low, balanced)
        XCTAssertLessThan(balanced, high)
    }

    func testForecastedReviewLoadLowersHiddenDesiredRetention() {
        let lightLoad = AdaptiveSessionPolicy.desiredRetention(
            pace: .balanced,
            forecastedReviewLoad: 4,
            recentAccuracy: 0.9
        )
        let heavyLoad = AdaptiveSessionPolicy.desiredRetention(
            pace: .balanced,
            forecastedReviewLoad: 60,
            recentAccuracy: 0.9
        )

        XCTAssertLessThan(heavyLoad, lightLoad)
        XCTAssertGreaterThanOrEqual(heavyLoad, LearningPace.balanced.retentionRange.lowerBound)
    }

    func testLowAccuracyRaisesRetentionPressureWhenLoadAllows() {
        let highAccuracy = AdaptiveSessionPolicy.desiredRetention(
            pace: .balanced,
            forecastedReviewLoad: 12,
            recentAccuracy: 0.95
        )
        let lowAccuracy = AdaptiveSessionPolicy.desiredRetention(
            pace: .balanced,
            forecastedReviewLoad: 12,
            recentAccuracy: 0.65
        )

        XCTAssertGreaterThan(lowAccuracy, highAccuracy)
        XCTAssertLessThanOrEqual(lowAccuracy, LearningPace.balanced.retentionRange.upperBound)
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

    func testNewCardsAreBraidedAcrossVocabularyAndRecognitionTypes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = ["word-1", "word-2", "word-3"].flatMap { noteSourceID in
            [
                SessionCardCandidate(
                    id: UUID(),
                    dueAt: now,
                    isNew: true,
                    recentLapses: 0,
                    noteSourceID: noteSourceID,
                    kind: .hanziToMeaning
                ),
                SessionCardCandidate(
                    id: UUID(),
                    dueAt: now,
                    isNew: true,
                    recentLapses: 0,
                    noteSourceID: noteSourceID,
                    kind: .hanziToPinyin
                ),
                SessionCardCandidate(
                    id: UUID(),
                    dueAt: now,
                    isNew: true,
                    recentLapses: 0,
                    noteSourceID: noteSourceID,
                    kind: .recall
                )
            ]
        }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .high,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertEqual(
            decision.orderedCards.prefix(3).map(\.noteSourceID),
            ["word-1", "word-2", "word-3"]
        )
        XCTAssertEqual(
            decision.orderedCards.prefix(6).map(\.kind),
            [
                .hanziToMeaning,
                .hanziToPinyin,
                .hanziToMeaning,
                .hanziToPinyin,
                .hanziToMeaning,
                .hanziToPinyin
            ]
        )
        XCTAssertEqual(
            decision.orderedCards.suffix(3).map(\.kind),
            [.recall, .recall, .recall]
        )
    }

    func testHighPaceKeepsExploringDuringEarlyCalibration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reviewedCards = (0..<8).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<90).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: reviewedCards + newCards,
            pace: .high,
            recentAccuracy: 0.35,
            now: now
        )

        XCTAssertGreaterThanOrEqual(decision.orderedCards.filter(\.isNew).count, 72)
    }

    func testHighPaceCalibrationFloorExpiresAfterEnoughReviewedCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reviewedCards = (0..<185).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<40).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: reviewedCards + newCards,
            pace: .high,
            recentAccuracy: 0.35,
            now: now
        )

        XCTAssertTrue(decision.orderedCards.filter(\.isNew).isEmpty)
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

    func testHighPaceStillExploresAfterDueWorkIsClearWhenForecastIsFull() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<120).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<40).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(
                from: futureReviews + newCards,
                pace: .high,
                recentAccuracy: 0.9,
                now: now
            ).orderedCards.filter(\.isNew).count,
            LearningPace.high.explorationNewCardBatch
        )

        XCTAssertEqual(
            AdaptiveSessionPolicy.chooseCards(
                from: futureReviews + newCards,
                pace: .high,
                recentAccuracy: 0.9,
                now: now,
                forceNewCards: true
            ).orderedCards.filter(\.isNew).count,
            LearningPace.high.forcedContinueNewCardBatch
        )
    }

    func testFullForecastDoesNotExploreWhenDueReviewsRemain() {
        let now = Date(timeIntervalSince1970: 1_000)
        let dueReviews = (0..<4).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(-index - 1) * 60),
                isNew: false,
                recentLapses: 0
            )
        }
        let futureReviews = (0..<120).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 3_600),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<40).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: dueReviews + futureReviews + newCards,
            pace: .high,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertEqual(decision.orderedCards.filter(\.isNew).count, 0)
        XCTAssertEqual(decision.orderedCards.count, dueReviews.count)
        XCTAssertTrue(decision.orderedCards.allSatisfy { !$0.isNew && $0.dueAt <= now })
    }

    func testForcedContinuePrioritizesNewCardsOverDueReviews() {
        let now = Date(timeIntervalSince1970: 1_000)
        let dueReview = SessionCardCandidate(
            id: UUID(),
            dueAt: now.addingTimeInterval(-60),
            isNew: false,
            recentLapses: 0
        )
        let newCard = SessionCardCandidate(id: UUID(), dueAt: now, isNew: true, recentLapses: 0)

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: [dueReview, newCard],
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now,
            forceNewCards: true
        )

        XCTAssertEqual(decision.orderedCards.first, newCard)
    }
}
