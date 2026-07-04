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

    func testStudyInteractionPolicyUsesMultipleChoiceForFreshRecognitionCards() {
        XCTAssertEqual(
            StudyInteractionPolicy.mode(kind: .hanziToMeaning, isNew: true, lastGrade: nil),
            .multipleChoice
        )
        XCTAssertEqual(
            StudyInteractionPolicy.mode(kind: .hanziToPinyin, isNew: true, lastGrade: nil),
            .multipleChoice
        )
    }

    func testStudyInteractionPolicyUsesRevealForReviewsAndAgains() {
        XCTAssertEqual(
            StudyInteractionPolicy.mode(kind: .hanziToMeaning, isNew: false, lastGrade: .good),
            .reveal
        )
        XCTAssertEqual(
            StudyInteractionPolicy.mode(kind: .hanziToPinyin, isNew: true, lastGrade: .again),
            .reveal
        )
        XCTAssertEqual(
            StudyInteractionPolicy.mode(kind: .recall, isNew: true, lastGrade: nil),
            .reveal
        )
    }

    func testCardSelectionExplanationNamesNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)

        let explanation = CardSelectionExplainer.explanation(
            isNew: true,
            dueAt: now,
            duplicateCount: 1,
            lastGrade: nil,
            now: now
        )

        XCTAssertEqual(explanation.title, "New card")
        XCTAssertTrue(explanation.detail.contains("new-card allowance"))
    }

    func testCardSelectionExplanationNamesAgainReviews() {
        let now = Date(timeIntervalSince1970: 1_000)

        let explanation = CardSelectionExplainer.explanation(
            isNew: false,
            dueAt: now,
            duplicateCount: 1,
            lastGrade: .again,
            now: now
        )

        XCTAssertEqual(explanation.title, "Again")
        XCTAssertTrue(explanation.detail.contains("missed"))
    }

    func testCardSelectionExplanationNamesDuplicateRecordsBeforeAgain() {
        let now = Date(timeIntervalSince1970: 1_000)

        let explanation = CardSelectionExplainer.explanation(
            isNew: false,
            dueAt: now,
            duplicateCount: 2,
            lastGrade: .again,
            now: now
        )

        XCTAssertEqual(explanation.title, "Duplicate record")
        XCTAssertTrue(explanation.detail.contains("2"))
    }

    func testServingCountersConsumeCorrectReview() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var counters = ServingCounters(cards: [
            candidate(id: reviewID, noteSourceID: "hsk2-0001", isNew: false),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, noteSourceID: "hsk2-0002", isNew: true),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, noteSourceID: "hsk2-0003", isNew: true),
        ])

        counters.consumeReview(
            cardID: reviewID,
            noteSourceID: "hsk2-0001",
            wasNew: false,
            grade: .good,
            scheduledDueAt: now.addingTimeInterval(60 * 60 * 24),
            now: now
        )

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 2)
        XCTAssertEqual(counters.review, 0)
        XCTAssertEqual(counters.plannedTotal, 3)
    }

    func testServingCountersKeepAgainReviewInCurrentServingPlan() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        var counters = ServingCounters(cards: [
            candidate(id: reviewID, noteSourceID: "hsk2-0001", isNew: false),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, noteSourceID: "hsk2-0002", isNew: true),
        ])

        counters.consumeReview(
            cardID: reviewID,
            noteSourceID: "hsk2-0001",
            wasNew: false,
            grade: .again,
            scheduledDueAt: now,
            now: now
        )

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 1)
        XCTAssertEqual(counters.review, 1)
        XCTAssertEqual(counters.plannedTotal, 2)
    }

    func testServingCountersMoveAgainNewCardIntoReviews() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        var counters = ServingCounters(cards: [
            candidate(id: newID, noteSourceID: "hsk2-0001", isNew: true),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, noteSourceID: "hsk2-0002", isNew: true),
        ])

        counters.consumeReview(
            cardID: newID,
            noteSourceID: "hsk2-0001",
            wasNew: true,
            grade: .again,
            scheduledDueAt: now,
            now: now
        )

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 1)
        XCTAssertEqual(counters.review, 1)
        XCTAssertEqual(counters.plannedTotal, 2)
    }

    func testServingCountersCanReincludeOriginalCardAsReviewWhenItReturnsDue() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        var counters = ServingCounters(cards: [
            candidate(id: cardID, noteSourceID: "hsk2-0001", isNew: true),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, noteSourceID: "hsk2-0002", isNew: true),
        ])

        counters.consumeReview(
            cardID: cardID,
            noteSourceID: "hsk2-0001",
            wasNew: true,
            grade: .hard,
            scheduledDueAt: now,
            now: now
        )

        let returnedDueReview = candidate(id: cardID, noteSourceID: "hsk2-0001", isNew: false)

        XCTAssertFalse(counters.contains(returnedDueReview))

        counters.includeLiveChange(returnedDueReview)

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 1)
        XCTAssertEqual(counters.review, 1)
        XCTAssertEqual(counters.plannedTotal, 2)
    }

    func testServingCountersRollGeneratedCardsUpToVocabularyEntries() {
        let now = Date(timeIntervalSince1970: 1_000)
        let meaningID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        let pinyinID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        var counters = ServingCounters(cards: [
            candidate(id: meaningID, noteSourceID: "hsk2-0001", isNew: true),
            candidate(id: pinyinID, noteSourceID: "hsk2-0001", isNew: true),
            candidate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, noteSourceID: "hsk2-0002", isNew: false),
        ])

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 1)
        XCTAssertEqual(counters.review, 1)

        counters.consumeReview(
            cardID: meaningID,
            noteSourceID: "hsk2-0001",
            wasNew: true,
            grade: .good,
            scheduledDueAt: now.addingTimeInterval(60 * 60 * 24),
            now: now
        )

        XCTAssertEqual(counters.total, 2)
        XCTAssertEqual(counters.new, 1)
        XCTAssertEqual(counters.review, 1)
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

    func testPinyinDistractorsDoNotFallBackToWrongSyllableCount() {
        let correct = "zhōng guó"
        let choices = MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: ["èr", "bù", "wǒ", "bà ba", "lǎo shī"],
            seed: "hsk2-9999#hanziToPinyin",
            preferredSyllableCount: MultipleChoiceBuilder.pinyinSyllableCount(correct)
        )

        XCTAssertEqual(choices.count, 3)
        XCTAssertTrue(choices.contains(correct))
        XCTAssertTrue(
            choices
                .filter { $0 != correct }
                .allSatisfy { MultipleChoiceBuilder.pinyinSyllableCount($0) == 2 }
        )
    }

    func testMultipleChoiceSeedIsStableButCanVaryBetweenPresentations() {
        let correct = "to study"
        let pool = [
            "to swim",
            "yellow",
            "surrounding area",
            "to live",
            "to ask",
            "to rest",
            "to arrive",
            "to prepare"
        ]
        let first = MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: pool,
            seed: "card#presentation-1"
        )
        let samePresentation = MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: pool,
            seed: "card#presentation-1"
        )
        let presentationVariants = (2...12).map { index in
            MultipleChoiceBuilder.choices(
                correctAnswer: correct,
                distractorPool: pool,
                seed: "card#presentation-\(index)"
            )
        }

        XCTAssertEqual(first, samePresentation)
        XCTAssertTrue(presentationVariants.contains { $0 != first })
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
        let newCards = (0..<300).map { index in
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
        let newCards = (0..<700).map { index in
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

        XCTAssertEqual(LearningPace.low.reviewLoadBudget, 210)
        XCTAssertEqual(LearningPace.balanced.reviewLoadBudget, 420)
        XCTAssertEqual(LearningPace.high.reviewLoadBudget, 840)
        XCTAssertEqual(low, LearningPace.low.newCardsPerPassLimit)
        XCTAssertEqual(balanced, LearningPace.balanced.newCardsPerPassLimit)
        XCTAssertEqual(high, LearningPace.high.newCardsPerPassLimit)
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
            forecastedReviewLoad: 500,
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
        let futureReviews = (0..<400).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let highAccuracy = AdaptiveSessionPolicy.chooseCards(
            from: futureReviews + newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        ).orderedCards.count
        let lowAccuracy = AdaptiveSessionPolicy.chooseCards(
            from: futureReviews + newCards,
            pace: .balanced,
            recentAccuracy: 0.45,
            now: now
        ).orderedCards.count

        XCTAssertGreaterThan(lowAccuracy, 0)
        XCTAssertLessThan(lowAccuracy, highAccuracy)
    }

    func testNewCardsPreferVocabularyVarietyWhenLegacyVariantsExist() {
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

    func testHighPaceCanUseForecastBelowHardCapWhenAccuracyIsPoor() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }
        let low = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .low,
            recentAccuracy: 0.35,
            now: now
        ).orderedCards.filter(\.isNew).count
        let high = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .high,
            recentAccuracy: 0.35,
            now: now
        ).orderedCards.filter(\.isNew).count

        XCTAssertGreaterThan(high, low)
        XCTAssertLessThan(high, LearningPace.high.newCardsPerPassLimit)
    }

    func testForecastedReviewLoadReducesNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<400).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<700).map { index in
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

    func testNewCardsStudiedTodayReducesNormalNewCardAllowance() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let freshDay = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            newCardsStudiedToday: 0,
            now: now
        ).orderedCards.filter(\.isNew).count
        let nearSoftLimit = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            newCardsStudiedToday: LearningPace.balanced.newCardsPerDayLimit - 4,
            now: now
        ).orderedCards.filter(\.isNew).count
        let atSoftLimit = AdaptiveSessionPolicy.chooseCards(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            newCardsStudiedToday: LearningPace.balanced.newCardsPerDayLimit,
            now: now
        ).orderedCards.filter(\.isNew).count

        XCTAssertEqual(freshDay, LearningPace.balanced.newCardsPerPassLimit)
        XCTAssertEqual(nearSoftLimit, 4)
        XCTAssertEqual(atSoftLimit, 0)
    }

    func testNewCardIntakeForecastExplainsPassLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertEqual(forecast.newCardsToServe, LearningPace.balanced.newCardsPerPassLimit)
        XCTAssertEqual(forecast.limitingFactor, .passLimit)
        XCTAssertGreaterThan(forecast.workloadAllowance, forecast.passLimit)
    }

    func testNewCardIntakeForecastExplainsReviewBudgetLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<400).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
                isNew: false,
                recentLapses: 0
            )
        }
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: futureReviews + newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            now: now
        )

        XCTAssertEqual(forecast.limitingFactor, .reviewBudget)
        XCTAssertEqual(forecast.newCardsToServe, forecast.workloadAllowance)
        XCTAssertLessThan(forecast.newCardsToServe, forecast.passLimit)
    }

    func testRelearningDebtConsumesReviewBudgetForNewCardIntake() {
        let now = Date(timeIntervalSince1970: 1_000)
        let relearningReviews = (0..<LearningPace.low.reviewLoadBudget / 4).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(-index - 1) * 60),
                isNew: false,
                recentLapses: 4
            )
        }
        let newCards = (0..<80).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: relearningReviews + newCards,
            pace: .low,
            recentAccuracy: 0.55,
            now: now
        )

        XCTAssertGreaterThan(forecast.relearningDebt, 0)
        XCTAssertEqual(forecast.forecastedReviewLoad, relearningReviews.count + forecast.relearningDebt)
        XCTAssertEqual(forecast.newCardsToServe, 0)
        XCTAssertEqual(forecast.limitingFactor, .reviewBudget)
    }

    func testRelearningDebtOnlyPricesDueFailedCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let dueAgain = SessionCardCandidate(
            id: UUID(),
            dueAt: now.addingTimeInterval(-60),
            isNew: false,
            recentLapses: 2
        )
        let futureAgain = SessionCardCandidate(
            id: UUID(),
            dueAt: now.addingTimeInterval(60),
            isNew: false,
            recentLapses: 2
        )

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: [dueAgain, futureAgain],
            pace: .balanced,
            recentAccuracy: 0.8,
            now: now
        )

        XCTAssertEqual(forecast.relearningDebt, 6)
        XCTAssertEqual(forecast.forecastedReviewLoad, 8)
    }

    func testHistoryEstimatedNewCardCostReducesReviewBudgetAllowance() {
        let now = Date(timeIntervalSince1970: 8 * 24 * 60 * 60)
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }
        let history = (0..<12).flatMap { wordIndex in
            (0..<5).map { reviewIndex in
                ReviewHistoryEvent(
                    cardKey: "word-\(wordIndex)",
                    noteSourceID: "word-\(wordIndex)",
                    reviewedAt: now.addingTimeInterval(-24 * 60 * 60 + Double(reviewIndex * 60 * 60))
                )
            }
        }
        let historicalCost = AdaptiveSessionPolicy.historicalReviewLoadPerNewCard(
            from: history,
            now: now
        )

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            historicalReviewLoadPerNewCard: historicalCost,
            now: now
        )

        XCTAssertEqual(historicalCost, 35)
        XCTAssertEqual(forecast.expectedReviewLoadPerNewCard, 35)
        XCTAssertEqual(forecast.newCardsToServe, 12)
        XCTAssertEqual(forecast.limitingFactor, .reviewBudget)
    }

    func testSingleFreshExposureDoesNotExplodeHistoricalNewCardCost() {
        let now = Date(timeIntervalSince1970: 8 * 24 * 60 * 60)
        let history = (0..<12).map { wordIndex in
            ReviewHistoryEvent(
                cardKey: "word-\(wordIndex)",
                noteSourceID: "word-\(wordIndex)",
                reviewedAt: now.addingTimeInterval(-60 * 60)
            )
        }

        let historicalCost = AdaptiveSessionPolicy.historicalReviewLoadPerNewCard(
            from: history,
            now: now
        )

        XCTAssertEqual(historicalCost, 1)
    }

    func testNewCardIntakeForecastExplainsDailyLimit() {
        let now = Date(timeIntervalSince1970: 1_000)
        let newCards = (0..<700).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: true,
                recentLapses: 0
            )
        }

        let forecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: newCards,
            pace: .balanced,
            recentAccuracy: 0.9,
            newCardsStudiedToday: LearningPace.balanced.newCardsPerDayLimit - 4,
            now: now
        )

        XCTAssertEqual(forecast.newCardsToServe, 4)
        XCTAssertEqual(forecast.limitingFactor, .dailyLimit)
    }

    func testForcedContinueIntroducesNewCardsDespiteLowAccuracy() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<LearningPace.low.reviewLoadBudget).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
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

    func testFullForecastNeedsForcedContinueForNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let futureReviews = (0..<(LearningPace.high.reviewLoadBudget + 40)).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
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
            0
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
        let futureReviews = (0..<LearningPace.high.reviewLoadBudget).map { index in
            SessionCardCandidate(
                id: UUID(),
                dueAt: now.addingTimeInterval(Double(index + 1) * 60),
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

    func testLoadSheddingPrefersRepeatedAgainCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stableID = UUID()
        let strugglingID = UUID()
        let activeCards = [
            LoadSheddingCard(
                id: stableID,
                cardKey: "stable",
                noteSourceID: "stable",
                dueAt: now,
                isNew: false,
                isSuspended: false
            ),
            LoadSheddingCard(
                id: strugglingID,
                cardKey: "struggling",
                noteSourceID: "struggling",
                dueAt: now,
                isNew: false,
                isSuspended: false
            )
        ] + (0..<14).map { index in
            LoadSheddingCard(
                id: UUID(),
                cardKey: "filler-\(index)",
                noteSourceID: "filler-\(index)",
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: false,
                isSuspended: false
            )
        }
        let reviews = [
            LoadSheddingReview(cardKey: "stable", noteSourceID: "stable", reviewedAt: now, grade: .good, wasCorrect: true),
            LoadSheddingReview(cardKey: "stable", noteSourceID: "stable", reviewedAt: now.addingTimeInterval(-60), grade: .easy, wasCorrect: true),
            LoadSheddingReview(cardKey: "struggling", noteSourceID: "struggling", reviewedAt: now, grade: .again, wasCorrect: false),
            LoadSheddingReview(cardKey: "struggling", noteSourceID: "struggling", reviewedAt: now.addingTimeInterval(-60), grade: .again, wasCorrect: false),
            LoadSheddingReview(cardKey: "struggling", noteSourceID: "struggling", reviewedAt: now.addingTimeInterval(-120), grade: .hard, wasCorrect: true)
        ]

        let ids = LoadSheddingPolicy.cardIDsToSuspend(
            cards: activeCards,
            reviews: reviews,
            now: now
        )

        XCTAssertTrue(ids.contains(strugglingID))
        XCTAssertFalse(ids.contains(stableID))
    }

    func testLoadSheddingDoesNotSuspendTinyActiveSets() {
        let now = Date(timeIntervalSince1970: 1_000)
        let card = LoadSheddingCard(
            id: UUID(),
            cardKey: "struggling",
            noteSourceID: "struggling",
            dueAt: now,
            isNew: false,
            isSuspended: false
        )
        let reviews = [
            LoadSheddingReview(cardKey: "struggling", noteSourceID: "struggling", reviewedAt: now, grade: .again, wasCorrect: false),
            LoadSheddingReview(cardKey: "struggling", noteSourceID: "struggling", reviewedAt: now.addingTimeInterval(-60), grade: .again, wasCorrect: false)
        ]

        XCTAssertTrue(
            LoadSheddingPolicy.cardIDsToSuspend(cards: [card], reviews: reviews, now: now).isEmpty
        )
    }

    func testFrictionCardsIncludeMoreThanNextSuspendBatch() {
        let now = Date(timeIntervalSince1970: 1_000)
        let frictionCards = (0..<50).map { index in
            LoadSheddingCard(
                id: UUID(),
                cardKey: "struggling-\(index)",
                noteSourceID: "struggling-\(index)",
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: false,
                isSuspended: false
            )
        }
        let stableCards = (0..<250).map { index in
            LoadSheddingCard(
                id: UUID(),
                cardKey: "stable-\(index)",
                noteSourceID: "stable-\(index)",
                dueAt: now.addingTimeInterval(Double(index)),
                isNew: false,
                isSuspended: false
            )
        }
        let reviews = frictionCards.flatMap { card in
            [
                LoadSheddingReview(cardKey: card.cardKey, noteSourceID: card.noteSourceID, reviewedAt: now, grade: .again, wasCorrect: false),
                LoadSheddingReview(cardKey: card.cardKey, noteSourceID: card.noteSourceID, reviewedAt: now.addingTimeInterval(-60), grade: .again, wasCorrect: false)
            ]
        }

        let frictionIDs = LoadSheddingPolicy.frictionCardIDs(
            cards: frictionCards + stableCards,
            reviews: reviews,
            now: now
        )
        let batchIDs = LoadSheddingPolicy.cardIDsToSuspend(
            cards: frictionCards + stableCards,
            reviews: reviews,
            now: now
        )

        XCTAssertEqual(frictionIDs.count, 50)
        XCTAssertEqual(batchIDs.count, 30)
    }

    private func candidate(
        id: UUID,
        noteSourceID: String,
        isNew: Bool,
        dueAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> SessionCardCandidate {
        SessionCardCandidate(
            id: id,
            dueAt: dueAt,
            isNew: isNew,
            recentLapses: 0,
            noteSourceID: noteSourceID
        )
    }
}
