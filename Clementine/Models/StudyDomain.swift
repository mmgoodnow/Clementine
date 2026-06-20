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

    var newCardLimit: Int {
        switch self {
        case .low: 2
        case .balanced: 5
        case .high: 9
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
    static func chooseCards(
        from candidates: [SessionCardCandidate],
        pace: LearningPace,
        recentAccuracy: Double,
        now: Date
    ) -> SessionDecision {
        let dueReviews = candidates
            .filter { !$0.isNew && $0.dueAt <= now }
            .sorted { lhs, rhs in
                if lhs.recentLapses != rhs.recentLapses {
                    return lhs.recentLapses > rhs.recentLapses
                }
                return lhs.dueAt < rhs.dueAt
            }

        let newAllowance = newCardAllowance(
            pace: pace,
            dueReviewCount: dueReviews.count,
            recentAccuracy: recentAccuracy
        )

        let newCards = candidates
            .filter(\.isNew)
            .sorted { $0.dueAt < $1.dueAt }
            .prefix(newAllowance)

        let selected = dueReviews + Array(newCards)
        return SessionDecision(
            orderedCards: selected,
            shouldStopNaturally: selected.isEmpty
        )
    }

    private static func newCardAllowance(
        pace: LearningPace,
        dueReviewCount: Int,
        recentAccuracy: Double
    ) -> Int {
        guard recentAccuracy >= 0.72 else { return 0 }

        let pressurePenalty = dueReviewCount >= 12 ? 2 : dueReviewCount >= 6 ? 1 : 0
        return max(0, pace.newCardLimit - pressurePenalty)
    }
}
