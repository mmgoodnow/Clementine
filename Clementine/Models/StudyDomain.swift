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
        case .low: 210
        case .balanced: 420
        case .high: 840
        }
    }

    var newCardsPerPassLimit: Int {
        switch self {
        case .low: 18
        case .balanced: 36
        case .high: 72
        }
    }

    var newCardsPerDayLimit: Int {
        switch self {
        case .low: 36
        case .balanced: 72
        case .high: 144
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

    var forcedContinueNewCardBatch: Int {
        switch self {
        case .low: 3
        case .balanced: 9
        case .high: 18
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

enum MultipleChoiceBuilder {
    static func choices(
        correctAnswer: String,
        distractorPool: [String],
        seed: String,
        optionCount: Int = 4,
        preferredSyllableCount: Int? = nil
    ) -> [String] {
        let distractorCount = max(0, optionCount - 1)
        let rankedDistractors = uniqueValues(from: distractorPool)
            .filter { $0 != correctAnswer }
            .sorted {
                choiceRank($0, seed: "\(seed)#distractor") < choiceRank($1, seed: "\(seed)#distractor")
            }

        let distractors: [String]
        if let preferredSyllableCount {
            let matchingSyllableCount = rankedDistractors.filter {
                pinyinSyllableCount($0) == preferredSyllableCount
            }
            let fallback = rankedDistractors.filter {
                pinyinSyllableCount($0) != preferredSyllableCount
            }
            distractors = Array((matchingSyllableCount + fallback).prefix(distractorCount))
        } else {
            distractors = Array(rankedDistractors.prefix(distractorCount))
        }

        return ([correctAnswer] + distractors)
            .sorted {
                choiceRank($0, seed: "\(seed)#display") < choiceRank($1, seed: "\(seed)#display")
            }
    }

    static func pinyinSyllableCount(_ pinyin: String) -> Int {
        let tokens = pinyin
            .split { $0.isWhitespace || $0 == "-" || $0 == "/" }
            .filter { !$0.isEmpty }
        return max(1, tokens.count)
    }

    private static func uniqueValues(from values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            seen.insert(value).inserted
        }
    }

    private static func choiceRank(_ value: String, seed: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(seed)#\(value)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
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

struct NewCardIntakeForecast: Equatable {
    enum LimitingFactor: String, Equatable {
        case reviewBudget = "Review budget"
        case passLimit = "Pass limit"
        case dailyLimit = "Daily limit"
        case deck = "Deck"
        case none = "No limit"
    }

    var newCardsToServe: Int
    var availableNewCards: Int
    var forecastedReviewLoad: Int
    var reviewLoadBudget: Int
    var availableReviewBudget: Int
    var recentAccuracy: Double
    var desiredRetention: Double
    var expectedReviewLoadPerNewCard: Double
    var workloadAllowance: Int
    var passLimit: Int
    var dayLimit: Int
    var newCardsStudiedToday: Int
    var dailyRemaining: Int
    var limitingFactor: LimitingFactor
}

struct ReviewLoadForecastDay: Identifiable, Equatable {
    var id: Date { day }
    var day: Date
    var count: Int
}

enum AdaptiveSessionPolicy {
    private static let forecastHorizonDays = 7

    static func chooseCards(
        from candidates: [SessionCardCandidate],
        pace: LearningPace,
        recentAccuracy: Double,
        newCardsStudiedToday: Int = 0,
        now: Date,
        forceNewCards: Bool = false
    ) -> SessionDecision {
        let intakeForecast = newCardIntakeForecast(
            from: candidates,
            pace: pace,
            recentAccuracy: recentAccuracy,
            newCardsStudiedToday: newCardsStudiedToday,
            now: now,
            forceNewCards: forceNewCards
        )
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
            .orderedForNewCardIntroduction()
            .prefix(intakeForecast.newCardsToServe)

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

    static func reviewLoadForecastByDay(from candidates: [SessionCardCandidate], now: Date) -> [ReviewLoadForecastDay] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let days = (0..<forecastHorizonDays).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
        let grouped = Dictionary(grouping: candidates.filter { !$0.isNew }) {
            calendar.startOfDay(for: max($0.dueAt, now))
        }

        return days.map { day in
            ReviewLoadForecastDay(day: day, count: grouped[day]?.count ?? 0)
        }
    }

    static func newCardIntakeForecast(
        from candidates: [SessionCardCandidate],
        pace: LearningPace,
        recentAccuracy: Double,
        newCardsStudiedToday: Int = 0,
        now: Date,
        forceNewCards: Bool = false
    ) -> NewCardIntakeForecast {
        let availableNewCards = candidates.filter(\.isNew).count
        let forecastedReviewLoad = forecastedReviewLoad(from: candidates, now: now)
        let availableLoad = max(0, pace.reviewLoadBudget - forecastedReviewLoad)
        let forcedBatch = forceNewCards ? pace.forcedContinueNewCardBatch : 0

        let desiredRetention = desiredRetention(
            pace: pace,
            forecastedReviewLoad: forecastedReviewLoad,
            recentAccuracy: recentAccuracy
        )
        let normalizedAccuracy = min(max(recentAccuracy, 0.35), 0.98)
        let expectedReviewLoad = expectedReviewLoadPerNewCard(
            desiredRetention: desiredRetention,
            recentAccuracy: normalizedAccuracy
        )
        let workloadAllowance = availableLoad > 0
            ? Int(floor(Double(availableLoad) / expectedReviewLoad))
            : forcedBatch
        let dailyRemaining = max(0, pace.newCardsPerDayLimit - newCardsStudiedToday)
        let passLimit = forceNewCards
            ? min(pace.forcedContinueNewCardBatch, pace.newCardsPerPassLimit)
            : pace.newCardsPerPassLimit
        let allowance = min(
            max(forcedBatch, workloadAllowance),
            passLimit,
            dailyRemaining
        )
        let newCardsToServe = min(max(0, allowance), availableNewCards)

        return NewCardIntakeForecast(
            newCardsToServe: newCardsToServe,
            availableNewCards: availableNewCards,
            forecastedReviewLoad: forecastedReviewLoad,
            reviewLoadBudget: pace.reviewLoadBudget,
            availableReviewBudget: availableLoad,
            recentAccuracy: recentAccuracy,
            desiredRetention: desiredRetention,
            expectedReviewLoadPerNewCard: expectedReviewLoad,
            workloadAllowance: workloadAllowance,
            passLimit: passLimit,
            dayLimit: pace.newCardsPerDayLimit,
            newCardsStudiedToday: newCardsStudiedToday,
            dailyRemaining: dailyRemaining,
            limitingFactor: limitingFactor(
                newCardsToServe: newCardsToServe,
                availableNewCards: availableNewCards,
                workloadAllowance: workloadAllowance,
                passLimit: passLimit,
                dailyRemaining: dailyRemaining
            )
        )
    }

    static func nextCandidate(
        from orderedCards: [SessionCardCandidate],
        recentCardIDs: [UUID],
        recentNoteSourceIDs: [String]
    ) -> SessionCardCandidate? {
        let recentCardIDs = Set(recentCardIDs)
        let recentNoteSourceIDs = Set(recentNoteSourceIDs.filter { !$0.isEmpty })

        return orderedCards.first { candidate in
            !recentCardIDs.contains(candidate.id) &&
                (candidate.noteSourceID.isEmpty || !recentNoteSourceIDs.contains(candidate.noteSourceID))
        } ?? orderedCards.first { candidate in
            !recentCardIDs.contains(candidate.id)
        } ?? orderedCards.first
    }

    private static func expectedReviewLoadPerNewCard(
        desiredRetention: Double,
        recentAccuracy normalizedAccuracy: Double
    ) -> Double {
        let expectedRecallCost = 1.0
        let expectedForgetCost = 2.5
        let expectedReviewCost =
            normalizedAccuracy * expectedRecallCost +
            (1 - normalizedAccuracy) * expectedForgetCost
        let retentionPressure = desiredRetention / normalizedAccuracy
        return max(2.0, ceil(expectedReviewCost * retentionPressure * 3.5))
    }

    private static func limitingFactor(
        newCardsToServe: Int,
        availableNewCards: Int,
        workloadAllowance: Int,
        passLimit: Int,
        dailyRemaining: Int
    ) -> NewCardIntakeForecast.LimitingFactor {
        guard newCardsToServe > 0 else {
            if dailyRemaining == 0 { return .dailyLimit }
            return availableNewCards == 0 ? .deck : .reviewBudget
        }
        if newCardsToServe == availableNewCards { return .deck }

        let minimum = min(workloadAllowance, passLimit, dailyRemaining)
        if dailyRemaining == minimum { return .dailyLimit }
        if passLimit == minimum { return .passLimit }
        if workloadAllowance == minimum { return .reviewBudget }
        return .none
    }

    private static func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}

private extension Array where Element == SessionCardCandidate {
    func orderedForNewCardIntroduction() -> [SessionCardCandidate] {
        let grouped = Dictionary(grouping: self) { candidate in
            candidate.noteSourceID.isEmpty ? candidate.id.uuidString : candidate.noteSourceID
        }
        let orderedNoteKeys = grouped.keys.sorted { lhs, rhs in
            let lhsDueAt = grouped[lhs]?.map(\.dueAt).min() ?? .distantFuture
            let rhsDueAt = grouped[rhs]?.map(\.dueAt).min() ?? .distantFuture
            if lhsDueAt != rhsDueAt { return lhsDueAt < rhsDueAt }
            return lhs < rhs
        }
        let noteRank = Dictionary(uniqueKeysWithValues: orderedNoteKeys.enumerated().map { ($1, $0) })

        return sorted { lhs, rhs in
            let lhsNoteKey = lhs.noteSourceID.isEmpty ? lhs.id.uuidString : lhs.noteSourceID
            let rhsNoteKey = rhs.noteSourceID.isEmpty ? rhs.id.uuidString : rhs.noteSourceID
            let lhsNoteRank = noteRank[lhsNoteKey] ?? 0
            let rhsNoteRank = noteRank[rhsNoteKey] ?? 0
            let lhsKindRank = braidedKindRank(for: lhs.kind, noteRank: lhsNoteRank)
            let rhsKindRank = braidedKindRank(for: rhs.kind, noteRank: rhsNoteRank)

            if lhsKindRank != rhsKindRank { return lhsKindRank < rhsKindRank }
            if lhsNoteRank != rhsNoteRank { return lhsNoteRank < rhsNoteRank }
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func braidedKindRank(for kind: CardKind, noteRank: Int) -> Int {
        switch kind {
        case .hanziToMeaning:
            noteRank.isMultiple(of: 2) ? 0 : 1
        case .hanziToPinyin:
            noteRank.isMultiple(of: 2) ? 1 : 0
        case .recall:
            2
        }
    }
}
