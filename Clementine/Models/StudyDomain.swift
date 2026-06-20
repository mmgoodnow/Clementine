import Foundation

enum CardKind: String, Codable, CaseIterable, Identifiable {
    case hanziToMeaning
    case hanziToPinyin
    case recall

    var id: Self { self }

    var title: String {
        switch self {
        case .hanziToMeaning: "Meaning"
        case .hanziToPinyin: "Pinyin"
        case .recall: "Recall"
        }
    }
}

enum LearningPace: String, Codable, CaseIterable, Identifiable {
    case low
    case balanced
    case high

    var id: Self { self }

    var title: String {
        switch self {
        case .low: "Low"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    var reviewLoadBudget: Int {
        switch self {
        case .low: 18
        case .balanced: 42
        case .high: 84
        }
    }

    var baselineRetention: Double {
        switch self {
        case .low: 0.88
        case .balanced: 0.90
        case .high: 0.92
        }
    }

    var retentionRange: ClosedRange<Double> {
        switch self {
        case .low: 0.84...0.90
        case .balanced: 0.86...0.92
        case .high: 0.88...0.95
        }
    }
}

enum ReviewGrade: String, Codable, CaseIterable {
    case again
    case hard
    case good
    case easy
}

enum ReviewInteraction: String, Codable {
    case multipleChoice
    case recall
}

struct ReviewOutcome: Equatable {
    var grade: ReviewGrade
    var wasCorrect: Bool
    var responseSeconds: TimeInterval
    var interaction: ReviewInteraction
}

enum ReviewGradeMapper {
    static func multipleChoice(correct: Bool, responseSeconds: TimeInterval) -> ReviewGrade {
        guard correct else { return .again }
        if responseSeconds > 8 { return .hard }
        if responseSeconds <= 2.5 { return .easy }
        return .good
    }

    static func recall(remembered: Bool, confident: Bool) -> ReviewGrade {
        guard remembered else { return .again }
        return confident ? .good : .hard
    }
}

struct SessionCardCandidate: Identifiable, Equatable {
    var id: UUID
    var dueAt: Date
    var isNew: Bool
    var recentLapses: Int
}

struct SessionDecision: Equatable {
    var orderedCards: [SessionCardCandidate]
    var shouldStopNaturally: Bool
}

enum AdaptiveSessionPolicy {
    private static let forecastHorizonDays = 7

    static func chooseCards(
        from candidates: [SessionCardCandidate],
        pace: LearningPace,
        recentAccuracy: Double,
        now: Date,
        forceNewCards: Bool = false
    ) -> SessionDecision {
        let forecastedReviewLoad = forecastedReviewLoad(from: candidates, now: now)
        let dueReviews = candidates
            .filter { !$0.isNew && $0.dueAt <= now }
            .sorted { lhs, rhs in
                if lhs.recentLapses != rhs.recentLapses {
                    return lhs.recentLapses > rhs.recentLapses
                }
                return lhs.dueAt < rhs.dueAt
            }

        let newCards = candidates
            .filter(\.isNew)
            .sorted { $0.dueAt < $1.dueAt }
            .prefix(
                newCardAllowance(
                    pace: pace,
                    forecastedReviewLoad: forecastedReviewLoad,
                    recentAccuracy: recentAccuracy,
                    forceNewCards: forceNewCards
                )
            )

        let selected = dueReviews + Array(newCards)
        return SessionDecision(
            orderedCards: selected,
            shouldStopNaturally: selected.isEmpty
        )
    }

    static func desiredRetention(
        pace: LearningPace,
        forecastedReviewLoad: Int,
        recentAccuracy: Double
    ) -> Double {
        let normalizedAccuracy = min(max(recentAccuracy, 0.35), 0.99)
        let loadRatio = Double(forecastedReviewLoad) / Double(max(1, pace.reviewLoadBudget))
        let accuracyAdjustment = clamp(
            (pace.baselineRetention - normalizedAccuracy) * 0.25,
            min: -0.015,
            max: 0.025
        )
        let loadAdjustment: Double
        if loadRatio > 0.85 {
            loadAdjustment = -min(0.045, (loadRatio - 0.85) * 0.18)
        } else if loadRatio < 0.45 {
            loadAdjustment = min(0.02, (0.45 - loadRatio) * 0.05)
        } else {
            loadAdjustment = 0
        }

        return clamp(
            pace.baselineRetention + accuracyAdjustment + loadAdjustment,
            min: pace.retentionRange.lowerBound,
            max: pace.retentionRange.upperBound
        )
    }

    static func forecastedReviewLoad(from candidates: [SessionCardCandidate], now: Date) -> Int {
        let horizonEnd = Calendar.current.date(byAdding: .day, value: forecastHorizonDays, to: now) ?? now
        return candidates.filter {
            !$0.isNew && $0.dueAt <= horizonEnd
        }.count
    }

    private static func newCardAllowance(
        pace: LearningPace,
        forecastedReviewLoad: Int,
        recentAccuracy: Double,
        forceNewCards: Bool
    ) -> Int {
        let availableLoad = pace.reviewLoadBudget - forecastedReviewLoad
        guard availableLoad > 0 else { return forceNewCards ? 1 : 0 }

        let expectedRecallCost = 1.0
        let expectedForgetCost = 2.0
        let normalizedAccuracy = min(max(recentAccuracy, 0.35), 0.98)
        let expectedReviewCost =
            normalizedAccuracy * expectedRecallCost +
            (1 - normalizedAccuracy) * expectedForgetCost
        let retentionPressure = desiredRetention(
            pace: pace,
            forecastedReviewLoad: forecastedReviewLoad,
            recentAccuracy: recentAccuracy
        ) / normalizedAccuracy
        let expectedNewCardLoad = max(2.0, ceil(expectedReviewCost * retentionPressure * 3.0))

        return max(forceNewCards ? 1 : 0, Int(floor(Double(availableLoad) / expectedNewCardLoad)))
    }

    private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}
