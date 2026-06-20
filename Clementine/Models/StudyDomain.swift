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

    var studyOrder: Int {
        switch self {
        case .hanziToMeaning: 0
        case .hanziToPinyin: 1
        case .recall: 2
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

    func calibrationNewCardFloor(reviewedCardCount: Int) -> Int {
        guard self == .high else { return 0 }
        return switch reviewedCardCount {
        case 0..<60: 72
        case 60..<120: 48
        case 120..<180: 30
        default: 0
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
    var noteSourceID: String = ""
    var kind: CardKind = .hanziToMeaning

    init(
        id: UUID,
        dueAt: Date,
        isNew: Bool,
        recentLapses: Int,
        noteSourceID: String = "",
        kind: CardKind = .hanziToMeaning
    ) {
        self.id = id
        self.dueAt = dueAt
        self.isNew = isNew
        self.recentLapses = recentLapses
        self.noteSourceID = noteSourceID
        self.kind = kind
    }
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
        let reviewedCardCount = candidates.filter { !$0.isNew }.count
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
            .sorted(by: newCardPrecedence)
            .prefix(
                newCardAllowance(
                    pace: pace,
                    forecastedReviewLoad: forecastedReviewLoad,
                    reviewedCardCount: reviewedCardCount,
                    recentAccuracy: recentAccuracy,
                    forceNewCards: forceNewCards
                )
            )

        let selected = forceNewCards ? Array(newCards) + dueReviews : dueReviews + Array(newCards)
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
        reviewedCardCount: Int,
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
        let workloadAllowance = Int(floor(Double(availableLoad) / expectedNewCardLoad))
        let calibrationFloor = min(
            availableLoad,
            pace.calibrationNewCardFloor(reviewedCardCount: reviewedCardCount)
        )

        return max(forceNewCards ? 1 : 0, calibrationFloor, workloadAllowance)
    }

    private static func newCardPrecedence(lhs: SessionCardCandidate, rhs: SessionCardCandidate) -> Bool {
        if lhs.kind.studyOrder != rhs.kind.studyOrder {
            return lhs.kind.studyOrder < rhs.kind.studyOrder
        }
        if lhs.dueAt != rhs.dueAt {
            return lhs.dueAt < rhs.dueAt
        }
        return lhs.noteSourceID < rhs.noteSourceID
    }

    private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}
