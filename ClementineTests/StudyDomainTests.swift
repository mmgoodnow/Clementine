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
        var counters = ServingCounters(total: 54, new: 30, review: 24)

        counters.consumeReview(
            wasNew: false,
            grade: .good,
            scheduledDueAt: now.addingTimeInterval(60 * 60 * 24),
            now: now
        )

        XCTAssertEqual(counters, ServingCounters(total: 53, new: 30, review: 23, plannedTotal: 54))
        XCTAssertEqual(counters.plannedTotal, 54)
    }

    func testServingCountersKeepAgainReviewInCurrentServingPlan() {
        let now = Date(timeIntervalSince1970: 1_000)
        var counters = ServingCounters(total: 54, new: 30, review: 24)

        counters.consumeReview(
            wasNew: false,
            grade: .again,
            scheduledDueAt: now,
            now: now
        )

        XCTAssertEqual(counters, ServingCounters(total: 54, new: 30, review: 24))
        XCTAssertEqual(counters.plannedTotal, 54)
    }

    func testServingCountersMoveAgainNewCardIntoReviews() {
        let now = Date(timeIntervalSince1970: 1_000)
        var counters = ServingCounters(total: 54, new: 30, review: 24)

        counters.consumeReview(
            wasNew: true,
            grade: .again,
            scheduledDueAt: now,
            now: now
        )

        XCTAssertEqual(counters, ServingCounters(total: 54, new: 29, review: 25))
        XCTAssertEqual(counters.plannedTotal, 54)
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
}
