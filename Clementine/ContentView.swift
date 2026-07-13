import AVFoundation
import Charts
import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#endif

private struct ReviewUndoState {
    var cardID: UUID
    var previousCardData: Data?
    var previousDueAt: Date
    var previousUpdatedAt: Date
    var previousIsSuspended: Bool
    var previousSuspendedAt: Date?
    var reviewEvent: ReviewEvent
    var servingCounters: ServingCounters
    var servingPlannedCardIDs: Set<UUID>
    var isServingPassActive: Bool
    var activeCardID: UUID?
    var activeInteractionMode: StudyInteractionMode?
    var activeChoiceSeed: String
    var selectedChoice: String?
    var isAnswerRevealed: Bool
    var responseStartedAt: Date
    var previousLastReviewedSchedule: LastReviewedSchedule?
}

private struct LastReviewedSchedule: Equatable {
    var hanzi: String
    var pinyin: String
    var intervalText: String
}

struct ContentView: View {
    var seedError: Error?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \VocabularyNote.sourceID) private var notes: [VocabularyNote]
    @Query(sort: \StudyCard.dueAt) private var cards: [StudyCard]
    @Query(sort: \ReviewEvent.reviewedAt, order: .reverse) private var reviews: [ReviewEvent]
    @Query(sort: \CardStateEvent.changedAt) private var cardStateEvents: [CardStateEvent]
    @Query private var settingsRecords: [UserSettings]

    @State private var selectedTab: AppTab = .study
    @State private var activeCardID: UUID?
    @State private var activeInteractionMode: StudyInteractionMode?
    @State private var activeChoiceSeed = UUID().uuidString
    @State private var selectedChoice: String?
    @State private var isAnswerRevealed = false
    @State private var responseStartedAt = Date()
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var preferredSpeechVoice: AVSpeechSynthesisVoice?
    @State private var hasWarmedSpeechSynthesizer = false
    @State private var recentCardIDs: [UUID] = []
    @State private var recentNoteSourceIDs: [String] = []
    @State private var servingCounters = ServingCounters()
    @State private var servingPlannedCardIDs: Set<UUID> = []
    @State private var isServingPassActive = false
    @State private var lastReviewUndo: ReviewUndoState?
    @State private var lastReviewedSchedule: LastReviewedSchedule?
    @State private var displayPreferenceVersion = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                StudyView(
                    state: studyState,
                    selectedChoice: $selectedChoice,
                    isAnswerRevealed: $isAnswerRevealed,
                    seedError: seedError,
                    speak: speak,
                    chooseAnswer: chooseAnswer,
                    gradeReveal: gradeReveal,
                    continueSession: continuePastNaturalStop
                )
            }
            .tabItem { Label("Study", systemImage: "character.book.closed") }
            .tag(AppTab.study)

            NavigationStack {
                ProgressViewContent(
                    notes: notes,
                    cards: cards,
                    reviews: reviews,
                    cardStateEvents: cardStateEvents,
                    learningPace: settings?.learningPace ?? .balanced,
                    reduceActiveLoad: reduceActiveLoad,
                    resumeSuspendedCards: resumeSuspendedCards
                )
            }
            .tabItem { Label("Progress", systemImage: "chart.bar") }
            .tag(AppTab.progress)

            NavigationStack {
                SettingsViewContent(
                    learningPace: learningPaceBinding,
                    hanziScript: hanziScriptBinding,
                    hanziTypeface: hanziTypefaceBinding
                )
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            .tag(AppTab.settings)
        }
        .task {
            ensureSettings()
            deduplicateSyncedSeedData()
            moveToNextCard()
            prepareSpeech(for: activeNote)
        }
        .task {
            await periodicallyShowDueReviewsIfIdle()
        }
        .onChange(of: cards.count) { _, _ in
            deduplicateSyncedSeedData()
            if activeCard == nil {
                moveToNextCard()
            }
        }
        .onChange(of: notes.count) { _, _ in
            deduplicateSyncedSeedData()
        }
        .onChange(of: activeCardID) { _, _ in
            prepareSpeech(for: activeNote)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            showDueReviewsIfIdle()
        }
        .background(shakeUndoDetector)
    }

    @ViewBuilder
    private var shakeUndoDetector: some View {
        #if os(iOS)
        ShakeDetector(onShake: undoLastReview)
            .allowsHitTesting(false)
        #else
        EmptyView()
        #endif
    }

    private var settings: UserSettings? {
        settingsRecords.first
    }

    private var learningPaceBinding: Binding<LearningPace> {
        Binding(
            get: { settings?.learningPace ?? .balanced },
            set: { newValue in
                ensureSettings()
                settings?.learningPace = newValue
                try? modelContext.save()
                endServingPass()
                moveToNextCard()
            }
        )
    }

    private var hanziScriptBinding: Binding<HanziScript> {
        Binding(
            get: { settings?.hanziScript ?? .simplified },
            set: { newValue in
                ensureSettings()
                settings?.hanziScript = newValue
                displayPreferenceVersion += 1
                try? modelContext.save()
                prepareSpeech(for: activeNote)
            }
        )
    }

    private var hanziTypefaceBinding: Binding<HanziTypeface> {
        Binding(
            get: { settings?.hanziTypeface ?? .serif },
            set: { newValue in
                ensureSettings()
                settings?.hanziTypeface = newValue
                displayPreferenceVersion += 1
                try? modelContext.save()
            }
        )
    }

    private var recentAccuracy: Double {
        let recent = reviews.prefix(20)
        guard !recent.isEmpty else { return 1 }
        let correct = recent.filter(\.wasCorrect).count
        return Double(correct) / Double(recent.count)
    }

    private var newCardsStudiedToday: Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var seenCardKeys = Set<String>()
        var count = 0

        for review in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) {
            guard seenCardKeys.insert(review.cardKey).inserted else { continue }
            if review.reviewedAt >= startOfToday {
                count += 1
            }
        }

        return count
    }

    private var historicalReviewLoadPerNewCard: Double? {
        AdaptiveSessionPolicy.historicalReviewLoadPerNewCard(
            from: reviewHistoryEvents,
            now: Date()
        )
    }

    private var reviewHistoryEvents: [ReviewHistoryEvent] {
        reviews.map {
            ReviewHistoryEvent(
                cardKey: $0.cardKey,
                noteSourceID: $0.noteSourceID,
                reviewedAt: $0.reviewedAt,
                scheduledDueAt: $0.scheduledDueAt
            )
        }
    }

    private func currentDesiredRetention(
        now: Date,
        candidates: [SessionCardCandidate]
    ) -> Double {
        AdaptiveSessionPolicy.desiredRetention(
            pace: settings?.learningPace ?? .balanced,
            forecastedReviewLoad: AdaptiveSessionPolicy.forecastedReviewLoad(
                from: candidates,
                reviewHistoryEvents: reviewHistoryEvents,
                now: now
            ),
            recentAccuracy: recentAccuracy
        )
    }

    private var activeCard: StudyCard? {
        guard let activeCardID else { return nil }
        return cards.first { $0.id == activeCardID }
    }

    private var activeNote: VocabularyNote? {
        guard let activeCard else { return nil }
        return notes.first { $0.sourceID == activeCard.noteSourceID }
    }

    private var studyState: StudyScreenState {
        guard !notes.isEmpty, !cards.isEmpty else {
            return .empty
        }

        guard let activeCard, let activeNote else {
            return .complete
        }

        let introducedNoteSourceIDs = Set(
            cards
                .filter { !$0.isSuspended && $0.fsrsCardData != nil }
                .map(\.noteSourceID)
                .filter { !$0.isEmpty }
        )
        let unseenVocabularyCount = notes.filter { !introducedNoteSourceIDs.contains($0.sourceID) }.count
        let interactionMode = activeInteractionMode ?? interactionMode(for: activeCard)
        _ = displayPreferenceVersion

        return .card(
            StudyPrompt(
                note: activeNote,
                card: activeCard,
                correctAnswer: correctAnswer(for: activeCard, note: activeNote),
                choices: choices(for: activeCard, note: activeNote),
                interactionMode: interactionMode,
                servingCount: servingCounters.total,
                servingNewCount: servingCounters.new,
                servingReviewCount: servingCounters.review,
                unseenVocabularyCount: unseenVocabularyCount,
                lastReviewedSchedule: lastReviewedSchedule,
                hanziScript: settings?.hanziScript ?? .simplified,
                hanziTypeface: settings?.hanziTypeface ?? .serif
            )
        )
    }

    private func ensureSettings() {
        guard settingsRecords.isEmpty else { return }
        modelContext.insert(UserSettings())
        try? modelContext.save()
    }

    private func deduplicateSyncedSeedData() {
        let removedCount = (try? SeedDeduplicator.removeDuplicateSeedRecords(context: modelContext)) ?? 0
        if removedCount > 0, activeCard == nil {
            moveToNextCard()
        }
    }

    private func moveToNextCard(
        forceNewCards: Bool = false,
        forcedCards: [SessionCardCandidate]? = nil,
        now: Date = Date()
    ) {
        if forceNewCards {
            endServingPass()
        } else if forcedCards == nil, isServingPassActive, servingCounters.total <= 0 {
            endServingPass()
            activeCardID = nil
            activeInteractionMode = nil
            activeChoiceSeed = UUID().uuidString
            selectedChoice = nil
            isAnswerRevealed = false
            return
        }

        let recentAgainCounts = recentAgainCountsByCardKey
        let orderedCards: [SessionCardCandidate]
        if let forcedCards {
            orderedCards = forcedCards
        } else {
            let candidates = sessionCandidates(
                includeSuspended: true,
                recentAgainCounts: recentAgainCounts
            )
            let historicalReviewLoad = self.historicalReviewLoadPerNewCard

            orderedCards = AdaptiveSessionPolicy.chooseCards(
                from: candidates,
                loadCandidates: candidates,
                pace: settings?.learningPace ?? .balanced,
                recentAccuracy: recentAccuracy,
                newCardsStudiedToday: newCardsStudiedToday,
                historicalReviewLoadPerNewCard: historicalReviewLoad,
                reviewHistoryEvents: reviewHistoryEvents,
                now: now,
                forceNewCards: forceNewCards
            ).orderedCards
        }

        let selectedCandidate = AdaptiveSessionPolicy.nextCandidate(
            from: orderedCards,
            recentCardIDs: forcedCards == nil ? Array(recentCardIDs.suffix(3)) : [],
            recentNoteSourceIDs: forcedCards == nil ? Array(recentNoteSourceIDs.suffix(2)) : []
        )

        activeCardID = selectedCandidate?.id
        if let selectedCandidate,
           let selectedCard = cards.first(where: { $0.id == selectedCandidate.id }) {
            if selectedCard.isSuspended {
                selectedCard.isSuspended = false
                selectedCard.suspendedAt = nil
                selectedCard.updatedAt = now
                modelContext.insert(CardStateEvent(
                    cardKey: selectedCard.cardKey,
                    noteSourceID: selectedCard.noteSourceID,
                    changedAt: now,
                    isSuspended: false
                ))
                scheduleModelSave()
            }
            activeInteractionMode = interactionMode(for: selectedCard)
        } else {
            activeInteractionMode = nil
        }
        activeChoiceSeed = selectedCandidate.map { candidate in
            "\(candidate.id.uuidString)#\(now.timeIntervalSinceReferenceDate)#\(reviews.count)"
        } ?? UUID().uuidString
        if selectedCandidate == nil {
            endServingPass()
        } else if !isServingPassActive {
            startServingPass(with: orderedCards)
        }
        if let selectedCandidate {
            noteSelectedCandidate(selectedCandidate)
            rememberShown(candidate: selectedCandidate)
        }
        selectedChoice = nil
        isAnswerRevealed = false
        responseStartedAt = now
        prepareSpeech(for: activeNote)
    }

    private func rememberShown(candidate: SessionCardCandidate) {
        recentCardIDs.append(candidate.id)
        recentCardIDs = Array(recentCardIDs.suffix(6))
        if !candidate.noteSourceID.isEmpty {
            recentNoteSourceIDs.append(candidate.noteSourceID)
            recentNoteSourceIDs = Array(recentNoteSourceIDs.suffix(4))
        }
    }

    private func noteSelectedCandidate(_ candidate: SessionCardCandidate) {
        guard isServingPassActive else { return }

        if !servingCounters.contains(candidate) {
            servingCounters.includeLiveChange(candidate)
        }

        if !servingPlannedCardIDs.contains(candidate.id) {
            servingPlannedCardIDs.insert(candidate.id)
        }
    }

    private func endServingPass() {
        servingCounters = ServingCounters()
        servingPlannedCardIDs = []
        isServingPassActive = false
    }

    private func startServingPass(with cards: [SessionCardCandidate]) {
        servingCounters = ServingCounters(cards: cards)
        servingPlannedCardIDs = Set(cards.map(\.id))
        isServingPassActive = true
    }

    private func sessionCandidates(
        includeSuspended: Bool = false,
        recentAgainCounts: [String: Int]? = nil
    ) -> [SessionCardCandidate] {
        let lapseCounts = recentAgainCounts ?? recentAgainCountsByCardKey
        return cards
            .filter { includeSuspended || !$0.isSuspended }
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    isSuspended: card.isSuspended,
                    recentLapses: lapseCounts[card.cardKey] ?? 0,
                    cardKey: card.cardKey,
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
    }

    private func dueReviewCandidates(now: Date = Date()) -> [SessionCardCandidate] {
        let lapseCounts = recentAgainCountsByCardKey
        return AppBadgeUpdater.dueReviewCards(from: cards, now: now)
            .sorted { lhs, rhs in
                let lhsLapses = lapseCounts[lhs.cardKey] ?? 0
                let rhsLapses = lapseCounts[rhs.cardKey] ?? 0
                if lhsLapses != rhsLapses {
                    return lhsLapses > rhsLapses
                }
                if lhs.dueAt != rhs.dueAt {
                    return lhs.dueAt < rhs.dueAt
                }
                return lhs.cardKey < rhs.cardKey
            }
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: false,
                    isSuspended: false,
                    recentLapses: lapseCounts[card.cardKey] ?? 0,
                    cardKey: card.cardKey,
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
    }

    private var recentAgainCountsByCardKey: [String: Int] {
        var counts: [String: Int] = [:]
        for review in reviews where review.gradeRaw == ReviewGrade.again.rawValue {
            guard counts[review.cardKey, default: 0] < 12 else { continue }
            counts[review.cardKey, default: 0] += 1
        }
        return counts
    }

    private func continuePastNaturalStop() {
        let now = Date()
        if !dueReviewCandidates(now: now).isEmpty {
            moveToNextDueReview(now: now)
            return
        }

        moveToNextCard(forceNewCards: true)
    }

    private func showDueReviewsIfIdle(now: Date = Date()) {
        guard activeCard == nil, !dueReviewCandidates(now: now).isEmpty else { return }
        moveToNextDueReview(now: now)
    }

    private func periodicallyShowDueReviewsIfIdle() async {
        while !Task.isCancelled {
            showDueReviewsIfIdle()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func moveToNextDueReview(now: Date = Date()) {
        endServingPass()
        moveToNextCard(forcedCards: dueReviewCandidates(now: now), now: now)
    }

    private var suspendedCardCount: Int {
        cards.filter(\.isSuspended).count
    }

    private var loadSheddingCards: [LoadSheddingCard] {
        cards.map { card in
            LoadSheddingCard(
                id: card.id,
                cardKey: card.cardKey,
                noteSourceID: card.noteSourceID,
                dueAt: card.dueAt,
                isNew: card.fsrsCardData == nil,
                isSuspended: card.isSuspended
            )
        }
    }

    private var loadSheddingReviews: [LoadSheddingReview] {
        reviews.compactMap { review in
            guard let grade = ReviewGrade(rawValue: review.gradeRaw) else { return nil }
            return LoadSheddingReview(
                cardKey: review.cardKey,
                noteSourceID: review.noteSourceID,
                reviewedAt: review.reviewedAt,
                grade: grade,
                wasCorrect: review.wasCorrect
            )
        }
    }

    private func reduceActiveLoad(_ cardIDs: [UUID]) {
        let idsToSuspend = Set(cardIDs)
        guard !idsToSuspend.isEmpty else { return }

        let now = Date()
        for card in cards where idsToSuspend.contains(card.id) {
            card.isSuspended = true
            card.suspendedAt = now
            card.updatedAt = now
            modelContext.insert(CardStateEvent(
                cardKey: card.cardKey,
                noteSourceID: card.noteSourceID,
                changedAt: now,
                isSuspended: true
            ))
        }

        try? modelContext.save()
        endServingPass()
        if let activeCardID, idsToSuspend.contains(activeCardID) {
            self.activeCardID = nil
        }
        scheduleModelSave()
        refreshBadgeSoon()
        if selectedTab == .study {
            moveToNextCard()
        }
    }

    private func resumeSuspendedCards(_ cardIDs: [UUID]) {
        let idsToResume = Set(cardIDs)
        guard !idsToResume.isEmpty else { return }

        let now = Date()
        for card in cards where idsToResume.contains(card.id) {
            card.isSuspended = false
            card.suspendedAt = nil
            card.updatedAt = now
            modelContext.insert(CardStateEvent(
                cardKey: card.cardKey,
                noteSourceID: card.noteSourceID,
                changedAt: now,
                isSuspended: false
            ))
        }

        endServingPass()
        scheduleModelSave()
        refreshBadgeSoon()
        if selectedTab == .study {
            moveToNextCard()
        }
    }

    private func scheduleModelSave() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            try? modelContext.save()
        }
    }

    private func refreshBadgeSoon() {
        Task { @MainActor in
            await AppBadgeUpdater.refreshBadge(context: modelContext)
        }
    }

    private func choices(for card: StudyCard, note: VocabularyNote) -> [String] {
        let correct = correctAnswer(for: card, note: note)
        let sourceNotes = multipleChoiceDistractorNotes(for: card)
        let pool = sourceNotes
            .map { card.kind == .hanziToPinyin ? $0.pinyin : $0.english }
            .filter { $0 != correct }
        let preferredSyllableCount = card.kind == .hanziToPinyin
            ? MultipleChoiceBuilder.pinyinSyllableCount(correct)
            : nil

        return MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: pool,
            seed: "\(card.cardKey)#\(activeChoiceSeed)",
            preferredSyllableCount: preferredSyllableCount
        )
    }

    private func multipleChoiceDistractorNotes(for card: StudyCard) -> [VocabularyNote] {
        let reviewedNoteSourceIDs = Set(reviews.map(\.noteSourceID).filter { !$0.isEmpty })
        let unseenNotes = notes.filter {
            $0.sourceID != card.noteSourceID && !reviewedNoteSourceIDs.contains($0.sourceID)
        }
        if unseenNotes.count >= 3 {
            return unseenNotes
        }

        return notes.filter { $0.sourceID != card.noteSourceID }
    }

    private func correctAnswer(for card: StudyCard, note: VocabularyNote) -> String {
        card.kind == .hanziToPinyin ? note.pinyin : note.english
    }

    private func interactionMode(for card: StudyCard) -> StudyInteractionMode {
        StudyInteractionPolicy.mode(
            kind: card.kind,
            isNew: card.fsrsCardData == nil,
            lastGrade: lastGrade(for: card)
        )
    }

    private func lastGrade(for card: StudyCard) -> ReviewGrade? {
        reviews
            .first { $0.cardKey == card.cardKey }
            .flatMap { ReviewGrade(rawValue: $0.gradeRaw) }
    }

    private func chooseAnswer(_ answer: String) {
        guard let activeCard, let activeNote else { return }
        let correct = answer == correctAnswer(for: activeCard, note: activeNote)
        let elapsed = Date().timeIntervalSince(responseStartedAt)
        let grade = ReviewGradeMapper.multipleChoice(correct: correct, responseSeconds: elapsed)
        speak(activeNote)
        applyReview(
            card: activeCard,
            note: activeNote,
            grade: grade,
            wasCorrect: correct,
            interaction: .multipleChoice,
            responseSeconds: elapsed,
            advanceImmediately: false
        )
        scheduleMultipleChoiceAdvance(cardID: activeCard.id, selectedAnswer: answer, wasCorrect: correct)
    }

    private func gradeReveal(_ grade: ReviewGrade) {
        guard let activeCard, let activeNote else { return }
        let elapsed = Date().timeIntervalSince(responseStartedAt)
        applyReview(
            card: activeCard,
            note: activeNote,
            grade: grade,
            wasCorrect: grade != .again,
            interaction: .recall,
            responseSeconds: elapsed
        )
    }

    private func applyReview(
        card: StudyCard,
        note: VocabularyNote,
        grade: ReviewGrade,
        wasCorrect: Bool,
        interaction: ReviewInteraction,
        responseSeconds: Double,
        advanceImmediately: Bool = true
    ) {
        do {
            let now = Date()
            let wasServingNewCard = card.fsrsCardData == nil
            let retentionCandidates = sessionCandidates(
                includeSuspended: true,
                recentAgainCounts: recentAgainCountsByCardKey
            )
            let desiredRetention = currentDesiredRetention(
                now: now,
                candidates: retentionCandidates
            )

            let review = try FSRSReviewScheduler.review(
                cardData: card.fsrsCardData,
                grade: grade,
                desiredRetention: desiredRetention,
                now: now
            )
            let reviewEvent = ReviewEvent(
                cardKey: card.cardKey,
                noteSourceID: note.sourceID,
                grade: grade,
                interaction: interaction,
                reviewedAt: now,
                scheduledDueAt: review.dueAt,
                wasCorrect: wasCorrect,
                responseSeconds: responseSeconds
            )

            lastReviewUndo = ReviewUndoState(
                cardID: card.id,
                previousCardData: card.fsrsCardData,
                previousDueAt: card.dueAt,
                previousUpdatedAt: card.updatedAt,
                previousIsSuspended: card.isSuspended,
                previousSuspendedAt: card.suspendedAt,
                reviewEvent: reviewEvent,
                servingCounters: servingCounters,
                servingPlannedCardIDs: servingPlannedCardIDs,
                isServingPassActive: isServingPassActive,
                activeCardID: activeCardID,
                activeInteractionMode: activeInteractionMode,
                activeChoiceSeed: activeChoiceSeed,
                selectedChoice: selectedChoice,
                isAnswerRevealed: isAnswerRevealed,
                responseStartedAt: responseStartedAt,
                previousLastReviewedSchedule: lastReviewedSchedule
            )

            card.fsrsCardData = review.cardData
            card.dueAt = review.dueAt
            card.updatedAt = now
            lastReviewedSchedule = LastReviewedSchedule(
                hanzi: note.hanzi,
                pinyin: note.pinyin,
                intervalText: review.dueAt.scheduleIntervalText(from: now)
            )

            modelContext.insert(reviewEvent)

            servingCounters.consumeReview(
                cardID: card.id,
                cardKey: card.cardKey,
                noteSourceID: note.sourceID,
                wasNew: wasServingNewCard,
                grade: grade,
                scheduledDueAt: review.dueAt,
                now: now
            )
            if advanceImmediately {
                moveToNextCard()
            }
            scheduleModelSave()
            refreshBadgeSoon()
        } catch {
            isAnswerRevealed = true
        }
    }

    private func undoLastReview() {
        guard let undo = lastReviewUndo,
              let card = cards.first(where: { $0.id == undo.cardID }) else { return }

        card.fsrsCardData = undo.previousCardData
        card.dueAt = undo.previousDueAt
        card.updatedAt = undo.previousUpdatedAt
        card.isSuspended = undo.previousIsSuspended
        card.suspendedAt = undo.previousSuspendedAt
        modelContext.delete(undo.reviewEvent)

        servingCounters = undo.servingCounters
        servingPlannedCardIDs = undo.servingPlannedCardIDs
        isServingPassActive = undo.isServingPassActive
        activeCardID = undo.activeCardID
        activeInteractionMode = undo.activeInteractionMode
        activeChoiceSeed = undo.activeChoiceSeed
        selectedChoice = undo.selectedChoice
        isAnswerRevealed = undo.isAnswerRevealed
        responseStartedAt = undo.responseStartedAt
        lastReviewedSchedule = undo.previousLastReviewedSchedule
        lastReviewUndo = nil
        prepareSpeech(for: activeNote)
        scheduleModelSave()
        refreshBadgeSoon()
    }

    private func scheduleMultipleChoiceAdvance(cardID: UUID, selectedAnswer: String, wasCorrect: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wasCorrect ? 0.6 : 0.85))
            guard activeCardID == cardID, selectedChoice == selectedAnswer else { return }
            moveToNextCard()
        }
    }

    private func speak(_ note: VocabularyNote) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let spokenHanzi = (settings?.hanziScript ?? .simplified).displayText(for: note.hanzi)
        speechSynthesizer.speak(mandarinUtterance(for: spokenHanzi))
    }

    private func prepareSpeech(for note: VocabularyNote?) {
        guard let note else { return }
        _ = cachedMandarinVoice()
        let spokenHanzi = (settings?.hanziScript ?? .simplified).displayText(for: note.hanzi)
        warmSpeechSynthesizerIfNeeded(with: spokenHanzi)
    }

    private func warmSpeechSynthesizerIfNeeded(with text: String) {
        guard !hasWarmedSpeechSynthesizer else { return }
        hasWarmedSpeechSynthesizer = true
        speechSynthesizer.speak(mandarinUtterance(for: text, volume: 0))
    }

    private func mandarinUtterance(for text: String, volume: Float = 1) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = cachedMandarinVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = volume
        return utterance
    }

    private func cachedMandarinVoice() -> AVSpeechSynthesisVoice? {
        if let preferredSpeechVoice {
            return preferredSpeechVoice
        }
        let voice = preferredMandarinVoice()
        preferredSpeechVoice = voice
        return voice
    }

    private func preferredMandarinVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" }

        return voices
            .filter { !$0.identifier.contains(".eloquence.") }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .first ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

private enum AppTab: Hashable {
    case study
    case progress
    case settings
}

private enum StudyScreenState {
    case empty
    case complete
    case card(StudyPrompt)
}

private struct StudyPrompt {
    var note: VocabularyNote
    var card: StudyCard
    var correctAnswer: String
    var choices: [String]
    var interactionMode: StudyInteractionMode
    var servingCount: Int
    var servingNewCount: Int
    var servingReviewCount: Int
    var unseenVocabularyCount: Int
    var lastReviewedSchedule: LastReviewedSchedule?
    var hanziScript: HanziScript
    var hanziTypeface: HanziTypeface
}

private struct StudyView: View {
    var state: StudyScreenState
    @Binding var selectedChoice: String?
    @Binding var isAnswerRevealed: Bool
    var seedError: Error?
    var speak: (VocabularyNote) -> Void
    var chooseAnswer: (String) -> Void
    var gradeReveal: (ReviewGrade) -> Void
    var continueSession: () -> Void

    var body: some View {
        ZStack {
            switch state {
            case .empty:
                EmptyStudyView(seedError: seedError)
            case .complete:
                CompleteStudyView(continueSession: continueSession)
            case .card(let prompt):
                StudyCardView(
                    prompt: prompt,
                    selectedChoice: $selectedChoice,
                    isAnswerRevealed: $isAnswerRevealed,
                    speak: speak,
                    chooseAnswer: chooseAnswer,
                    gradeReveal: gradeReveal
                )
            }
        }
        .navigationTitle("Clementine")
    }
}

private struct StudyCardView: View {
    var prompt: StudyPrompt
    @Binding var selectedChoice: String?
    @Binding var isAnswerRevealed: Bool
    var speak: (VocabularyNote) -> Void
    var chooseAnswer: (String) -> Void
    var gradeReveal: (ReviewGrade) -> Void

    var body: some View {
        VStack(spacing: 22) {
            StudyStatusBar(
                servingCount: prompt.servingCount,
                servingNewCount: prompt.servingNewCount,
                servingReviewCount: prompt.servingReviewCount,
                unseenVocabularyCount: prompt.unseenVocabularyCount,
                lastReviewedSchedule: prompt.lastReviewedSchedule,
                hanziScript: prompt.hanziScript
            )

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Text(prompt.hanziScript.displayText(for: prompt.note.hanzi))
                    .font(prompt.hanziTypeface.displayFont(size: 116, script: prompt.hanziScript))
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Hanzi \(prompt.hanziScript.displayText(for: prompt.note.hanzi))")

                Button {
                    speak(prompt.note)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Play Mandarin audio")
            }

            if prompt.interactionMode == .reveal {
                RevealControls(
                    prompt: prompt,
                    isAnswerRevealed: $isAnswerRevealed,
                    speak: speak,
                    gradeReveal: gradeReveal
                )
            } else {
                MultipleChoiceControls(
                    prompt: prompt,
                    selectedChoice: $selectedChoice,
                    chooseAnswer: chooseAnswer
                )
            }

            Spacer(minLength: 8)
        }
        .padding(28)
        .frame(maxWidth: 680, maxHeight: .infinity)
    }
}

private struct StudyStatusBar: View {
    var servingCount: Int
    var servingNewCount: Int
    var servingReviewCount: Int
    var unseenVocabularyCount: Int
    var lastReviewedSchedule: LastReviewedSchedule?
    var hanziScript: HanziScript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(servingCount) live · \(servingNewCount) new · \(servingReviewCount) review · \(unseenVocabularyCount) unseen")
                Spacer()
            }
            if let lastReviewedSchedule {
                Text("\(hanziScript.displayText(for: lastReviewedSchedule.hanzi)) · \(lastReviewedSchedule.pinyin) · \(lastReviewedSchedule.intervalText)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

#if os(iOS)
private struct ShakeDetector: UIViewRepresentable {
    var onShake: () -> Void

    func makeUIView(context: Context) -> ShakeDetectingView {
        let view = ShakeDetectingView()
        view.onShake = onShake
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: ShakeDetectingView, context: Context) {
        uiView.onShake = onShake
        if !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }
}

private final class ShakeDetectingView: UIView {
    var onShake: () -> Void = {}

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        onShake()
    }
}
#endif

private struct MultipleChoiceControls: View {
    var prompt: StudyPrompt
    @Binding var selectedChoice: String?
    var chooseAnswer: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(prompt.card.kind == .hanziToPinyin ? "Choose the pinyin" : "Choose the meaning")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(prompt.choices, id: \.self) { choice in
                Button {
                    withAnimation(.easeOut(duration: 0.05)) {
                        selectedChoice = choice
                    }
                    Task { @MainActor in
                        await Task.yield()
                        chooseAnswer(choice)
                    }
                } label: {
                    MultipleChoiceButtonLabel(
                        choice: choice,
                        selectedChoice: selectedChoice,
                        correctAnswer: prompt.correctAnswer
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .disabled(selectedChoice != nil)
            }
        }
    }
}

private struct MultipleChoiceButtonLabel: View {
    var choice: String
    var selectedChoice: String?
    var correctAnswer: String

    private var isAnswered: Bool {
        selectedChoice != nil
    }

    private var isSelected: Bool {
        selectedChoice == choice
    }

    private var isCorrect: Bool {
        choice == correctAnswer
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(choice)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if isAnswered {
                if isCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isSelected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(feedbackBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(optionForeground)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var feedbackBackground: Color {
        guard isAnswered else { return Color.primary.opacity(0.035) }
        if isCorrect { return Color.green.opacity(0.08) }
        if isSelected { return Color.red.opacity(0.07) }
        return Color.primary.opacity(0.025)
    }

    private var optionForeground: Color {
        return .primary
    }
}

private struct RevealControls: View {
    var prompt: StudyPrompt
    @Binding var isAnswerRevealed: Bool
    var speak: (VocabularyNote) -> Void
    var gradeReveal: (ReviewGrade) -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isAnswerRevealed {
                VStack(spacing: 6) {
                    Text(primaryAnswer)
                        .font(.title2.weight(.semibold))
                    if let secondaryAnswer {
                        Text(secondaryAnswer)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        RecallGradeButton(
                            title: "Again",
                            systemImage: "xmark",
                            prominence: .secondary
                        ) {
                            gradeReveal(.again)
                        }

                        RecallGradeButton(
                            title: "Hard",
                            systemImage: "exclamationmark",
                            prominence: .secondary
                        ) {
                            gradeReveal(.hard)
                        }

                        RecallGradeButton(
                            title: "Good",
                            systemImage: "checkmark",
                            prominence: .primary
                        ) {
                            gradeReveal(.good)
                        }

                        RecallGradeButton(
                            title: "Easy",
                            systemImage: "sparkles",
                            prominence: .secondary
                        ) {
                            gradeReveal(.easy)
                        }
                    }

                    VStack(spacing: 10) {
                        RecallGradeButton(
                            title: "Again",
                            systemImage: "xmark",
                            prominence: .secondary
                        ) {
                            gradeReveal(.again)
                        }

                        RecallGradeButton(
                            title: "Hard",
                            systemImage: "exclamationmark",
                            prominence: .secondary
                        ) {
                            gradeReveal(.hard)
                        }

                        RecallGradeButton(
                            title: "Good",
                            systemImage: "checkmark",
                            prominence: .primary
                        ) {
                            gradeReveal(.good)
                        }

                        RecallGradeButton(
                            title: "Easy",
                            systemImage: "sparkles",
                            prominence: .secondary
                        ) {
                            gradeReveal(.easy)
                        }
                    }
                }
                .controlSize(.large)
            } else {
                Text(recallPrompt)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button {
                    isAnswerRevealed = true
                    speak(prompt.note)
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var recallPrompt: String {
        switch prompt.card.kind {
        case .hanziToMeaning:
            "Recall the meaning"
        case .hanziToPinyin:
            "Recall the pinyin"
        case .recall:
            "Recall the pinyin and meaning"
        }
    }

    private var primaryAnswer: String {
        switch prompt.card.kind {
        case .hanziToMeaning:
            prompt.note.english
        case .hanziToPinyin:
            prompt.note.pinyin
        case .recall:
            prompt.note.pinyin
        }
    }

    private var secondaryAnswer: String? {
        switch prompt.card.kind {
        case .hanziToMeaning:
            prompt.note.pinyin
        case .hanziToPinyin:
            prompt.note.english
        case .recall:
            prompt.note.english
        }
    }
}

private struct RecallGradeButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    var title: String
    var systemImage: String
    var prominence: Prominence
    var action: () -> Void

    @ViewBuilder
    var body: some View {
        switch prominence {
        case .primary:
            button
                .buttonStyle(.borderedProminent)
        case .secondary:
            button
                .buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(minWidth: 82, maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 6)
                .contentShape(.rect)
        }
    }
}

private struct EmptyStudyView: View {
    var seedError: Error?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(seedError == nil ? "Preparing your HSK2 deck..." : "Could not load the seed deck.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

private struct CompleteStudyView: View {
    var continueSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("That is enough for now.")
                .font(.title.weight(.semibold))
            Text("Clementine will keep choosing useful work when you continue.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Continue", action: continueSession)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
}

private struct ProgressViewContent: View {
    var notes: [VocabularyNote]
    var cards: [StudyCard]
    var reviews: [ReviewEvent]
    var cardStateEvents: [CardStateEvent]
    var learningPace: LearningPace
    var reduceActiveLoad: ([UUID]) -> Void
    var resumeSuspendedCards: ([UUID]) -> Void

    var body: some View {
        let snapshot = progressSnapshot

        List {
            Section {
                HStack(spacing: 14) {
                    ProgressMetric(title: "Introduced", value: "\(snapshot.introducedVocabularyCount)", systemImage: "character.book.closed")
                    ProgressMetric(title: "Deck", value: "\(notes.count)", systemImage: "rectangle.stack")
                    ProgressMetric(title: "Reviews", value: "\(reviews.count)", systemImage: "checkmark.circle")
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Today") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        ProgressMetric(
                            title: "New Vocab",
                            value: "\(snapshot.intakeForecast.newCardsToServe)",
                            systemImage: "plus.rectangle.on.rectangle"
                        )
                        ProgressMetric(
                            title: "7-Day Due",
                            value: "\(snapshot.intakeForecast.forecastedReviewLoad)",
                            systemImage: "calendar"
                        )
                        ProgressMetric(
                            title: "Limited By",
                            value: snapshot.intakeForecast.limitingFactor.rawValue,
                            systemImage: "gauge.with.dots.needle.50percent"
                        )
                    }

                    VStack(spacing: 10) {
                        ForecastRow(
                            title: "Review budget",
                            value: "\(snapshot.intakeForecast.forecastedReviewLoad) / \(snapshot.intakeForecast.reviewLoadBudget)"
                        )
                        if snapshot.intakeForecast.relearningDebt > 0 {
                            ForecastRow(
                                title: "Relearning debt",
                                value: "+\(snapshot.intakeForecast.relearningDebt)"
                            )
                        }
                        ForecastRow(
                            title: "Available review room",
                            value: "\(snapshot.intakeForecast.availableReviewBudget)"
                        )
                        if snapshot.intakeForecast.reintroducedCardsToServe > 0 {
                            ForecastRow(
                                title: "Reintroductions",
                                value: "\(snapshot.intakeForecast.reintroducedCardsToServe)"
                            )
                        }
                        ForecastRow(
                            title: "Per-new-vocab cost",
                            value: snapshot.intakeForecast.expectedReviewLoadPerNewCard.formatted(.number.precision(.fractionLength(1)))
                        )
                        if let historicalReviewLoadPerNewCard = snapshot.intakeForecast.historicalReviewLoadPerNewCard {
                            ForecastRow(
                                title: "History estimate",
                                value: historicalReviewLoadPerNewCard.formatted(.number.precision(.fractionLength(1)))
                            )
                        }
                        ForecastRow(
                            title: "Accuracy",
                            value: snapshot.intakeForecast.recentAccuracy.formatted(.percent.precision(.fractionLength(0)))
                        )
                        ForecastRow(
                            title: "Retention target",
                            value: snapshot.intakeForecast.desiredRetention.formatted(.percent.precision(.fractionLength(0)))
                        )
                        ForecastRow(
                            title: "Today",
                            value: "\(snapshot.intakeForecast.newCardsStudiedToday) / \(snapshot.intakeForecast.dayLimit) new"
                        )
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Active Load") {
                HStack(spacing: 14) {
                    ProgressMetric(
                        title: "Active",
                        value: "\(snapshot.activeIntroducedCardCount)",
                        systemImage: "tray.full"
                    )
                    ProgressMetric(
                        title: "Friction",
                        value: "\(snapshot.frictionCardCount)",
                        systemImage: "exclamationmark.triangle"
                    )
                    ProgressMetric(
                        title: "Suspended",
                        value: "\(snapshot.suspendedCardCount)",
                        systemImage: "pause.circle"
                    )
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                Button {
                    reduceActiveLoad(snapshot.loadSheddingCandidateIDs)
                } label: {
                    Label("Reduce active load (\(snapshot.loadSheddingCandidateCount))", systemImage: "tray.and.arrow.down")
                }
                .disabled(snapshot.loadSheddingCandidateCount == 0)

                if snapshot.suspendedCardCount > 0 {
                    Button {
                        resumeSuspendedCards(snapshot.resumeSuspendedCardIDs)
                    } label: {
                        Label("Resume 12 suspended", systemImage: "arrow.uturn.up")
                    }
                    .disabled(snapshot.resumeSuspendedCardIDs.isEmpty)
                }
            }

            Section("Review Forecast") {
                Chart {
                    ForEach(snapshot.reviewLoadForecast) { point in
                        BarMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Due", point.count)
                        )
                        .foregroundStyle(.teal)
                    }
                    RuleMark(y: .value("Daily Budget", Double(learningPace.reviewLoadBudget) / 7.0))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
                .accessibilityLabel("Forecasted review load for the next seven days")
            }

            Section("Introduced Vocabulary") {
                if snapshot.introducedVocabularyPoints.isEmpty {
                    EmptyChartMessage(text: "Introduced vocabulary will appear after reviews.")
                } else {
	                    Chart(snapshot.introducedVocabularyPoints) { point in
	                        BarMark(
	                            x: .value("Day", point.day, unit: .day),
	                            y: .value("Introduced", point.count),
	                            stacking: .standard
	                        )
	                        .foregroundStyle(by: .value("State", point.bucket.label))
	                    }
	                    .chartForegroundStyleScale(IntroducedVocabularyDueBucket.chartStyles)
	                    .chartLegend(.hidden)
	                    .chartYAxis {
	                        AxisMarks(position: .leading)
	                    }
	                    .frame(height: 180)
	                    .accessibilityLabel("Cumulative introduced vocabulary grouped by historical state")
	                    IntroducedVocabularyLegend()
	                    Text("Cumulative vocabulary introduced by each day. Colors show each card's state on that day.")
	                        .font(.footnote)
	                        .foregroundStyle(.secondary)
                }
            }

            Section("Accuracy") {
                if snapshot.accuracyPoints.isEmpty {
                    EmptyChartMessage(text: "Accuracy will appear after reviews.")
                } else {
                    Chart(snapshot.accuracyPoints) { point in
                        BarMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Accuracy", point.accuracy)
                        )
                        .foregroundStyle(point.accuracy >= 0.8 ? .green : .orange)
                    }
                    .chartYScale(domain: 0...1)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let percent = value.as(Double.self) {
                                    Text(percent, format: .percent.precision(.fractionLength(0)))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Accuracy rate over time")
                }
            }

            Section("Study Mix") {
                if snapshot.reviewMixSegments.isEmpty {
                    EmptyChartMessage(text: "New and review mix will appear after reviews.")
                } else {
                    Chart(snapshot.reviewMixSegments) { segment in
                        BarMark(
                            x: .value("Day", segment.day, unit: .day),
                            y: .value("Cards", segment.count)
                        )
                        .foregroundStyle(by: .value("Type", segment.kind))
                    }
                    .chartForegroundStyleScale([
                        "New": Color.blue,
                        "Review": Color.indigo
                    ])
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)
                    .accessibilityLabel("New cards versus reviews")
                }
            }

            Section("Sync") {
                LabeledContent("Store", value: ClementineModelContainer.usesCloudKitSync ? "iCloud Private Database" : "Local Debug Store")
                LabeledContent("Container", value: ClementineModelContainer.iCloudContainerIdentifier)
            }
        }
        .navigationTitle("Progress")
    }

    private var progressSnapshot: ProgressSnapshot {
        let now = Date()
        let recentAgainCounts = recentAgainCountsByCardKey
        let selectableCandidates = cards
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    isSuspended: card.isSuspended,
                    recentLapses: recentAgainCounts[card.cardKey] ?? 0,
                    cardKey: card.cardKey,
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
        let workloadCandidates = cards
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    isSuspended: card.isSuspended,
                    recentLapses: recentAgainCounts[card.cardKey] ?? 0,
                    cardKey: card.cardKey,
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
        let reviewHistoryEvents = reviews.map {
            ReviewHistoryEvent(
                cardKey: $0.cardKey,
                noteSourceID: $0.noteSourceID,
                reviewedAt: $0.reviewedAt,
                scheduledDueAt: $0.scheduledDueAt
            )
        }
        let recentAccuracy = recentAccuracy
        let newCardsStudiedToday = newCardsStudiedToday
        let intakeForecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: selectableCandidates,
            loadCandidates: workloadCandidates,
            pace: learningPace,
            recentAccuracy: recentAccuracy,
            newCardsStudiedToday: newCardsStudiedToday,
            historicalReviewLoadPerNewCard: AdaptiveSessionPolicy.historicalReviewLoadPerNewCard(
                from: reviewHistoryEvents,
                now: now
            ),
            reviewHistoryEvents: reviewHistoryEvents,
            now: now
        )
        let loadSheddingCandidateIDs = LoadSheddingPolicy.cardIDsToSuspend(
            cards: loadSheddingCards,
            reviews: loadSheddingReviews,
            now: now
        )
        let frictionCardIDs = LoadSheddingPolicy.frictionCardIDs(
            cards: loadSheddingCards,
            reviews: loadSheddingReviews,
            now: now
        )
        let resumeSuspendedCardIDs = cards
            .filter(\.isSuspended)
            .sorted {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                return $0.cardKey < $1.cardKey
            }
            .prefix(12)
            .map(\.id)

        return ProgressSnapshot(
            introducedVocabularyCount: Set(reviews.map(\.noteSourceID).filter { !$0.isEmpty }).count,
            activeIntroducedCardCount: cards.filter { !$0.isSuspended && $0.fsrsCardData != nil }.count,
            suspendedCardCount: cards.filter(\.isSuspended).count,
            frictionCardCount: frictionCardIDs.count,
            loadSheddingCandidateCount: loadSheddingCandidateIDs.count,
            loadSheddingCandidateIDs: loadSheddingCandidateIDs,
            resumeSuspendedCardIDs: resumeSuspendedCardIDs,
            intakeForecast: intakeForecast,
            reviewLoadForecast: AdaptiveSessionPolicy.reviewLoadForecastByDay(
                from: workloadCandidates,
                reviewHistoryEvents: reviewHistoryEvents,
                now: now
            ),
            introducedVocabularyPoints: introducedVocabularyPoints(now: now),
            accuracyPoints: accuracyPoints,
            reviewMixSegments: reviewMixSegments
        )
    }

    private var recentAgainCountsByCardKey: [String: Int] {
        var counts: [String: Int] = [:]
        for review in reviews where review.gradeRaw == ReviewGrade.again.rawValue {
            guard counts[review.cardKey, default: 0] < 12 else { continue }
            counts[review.cardKey, default: 0] += 1
        }
        return counts
    }

    private var loadSheddingCards: [LoadSheddingCard] {
        cards.map { card in
            LoadSheddingCard(
                id: card.id,
                cardKey: card.cardKey,
                noteSourceID: card.noteSourceID,
                dueAt: card.dueAt,
                isNew: card.fsrsCardData == nil,
                isSuspended: card.isSuspended
            )
        }
    }

    private var loadSheddingReviews: [LoadSheddingReview] {
        reviews.compactMap { review in
            guard let grade = ReviewGrade(rawValue: review.gradeRaw) else { return nil }
            return LoadSheddingReview(
                cardKey: review.cardKey,
                noteSourceID: review.noteSourceID,
                reviewedAt: review.reviewedAt,
                grade: grade,
                wasCorrect: review.wasCorrect
            )
        }
    }

    private var recentAccuracy: Double {
        let recent = reviews.prefix(20)
        guard !recent.isEmpty else { return 1 }
        return Double(recent.filter(\.wasCorrect).count) / Double(recent.count)
    }

    private var newCardsStudiedToday: Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var seenCardKeys = Set<String>()
        var count = 0

        for review in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) {
            guard seenCardKeys.insert(review.cardKey).inserted else { continue }
            if review.reviewedAt >= startOfToday {
                count += 1
            }
        }

        return count
    }

    private func introducedVocabularyPoints(now: Date) -> [VocabularyPoint] {
        guard !reviews.isEmpty else { return [] }

        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        let earliest = reviews
            .map { calendar.startOfDay(for: $0.reviewedAt) }
            .min() ?? end
        let lastThirtyDays = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        let minimumWindowStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let start = min(max(earliest, lastThirtyDays), minimumWindowStart)
        let days = dateRange(from: start, to: end)
        let firstReviewDaysBySourceID = Dictionary(grouping: reviews.filter { !$0.noteSourceID.isEmpty }, by: \.noteSourceID)
            .compactMapValues { noteReviews in
                noteReviews.map(\.reviewedAt).min().map { calendar.startOfDay(for: $0) }
            }

        let introducedCardsBySourceID = Dictionary(
            cards.filter { card in
                card.fsrsCardData != nil && !card.noteSourceID.isEmpty
            }.map { card in
                (card.noteSourceID, card)
            },
            uniquingKeysWith: { lhs, rhs in
                if lhs.isSuspended != rhs.isSuspended {
                    return lhs.isSuspended ? rhs : lhs
                }
                return lhs.dueAt < rhs.dueAt ? lhs : rhs
            }
        )

        let reviewEventsBySourceID = Dictionary(grouping: reviews.filter { !$0.noteSourceID.isEmpty }, by: \.noteSourceID)
            .mapValues { events in
                events.sorted { $0.reviewedAt < $1.reviewedAt }
            }
	        let stateEventsBySourceID = Dictionary(grouping: cardStateEvents.filter { !$0.noteSourceID.isEmpty }, by: \.noteSourceID)
	            .mapValues { events in
	                events.sorted { $0.changedAt < $1.changedAt }
	            }
	        let sourceIDsWithStateEvents = Set(cardStateEvents.map(\.noteSourceID))
	        let inferredLegacySuspendedAt = introducedCardsBySourceID.values
	            .filter { card in
	                card.isSuspended
	                    && card.suspendedAt == nil
	                    && !sourceIDsWithStateEvents.contains(card.noteSourceID)
	            }
	            .map(\.updatedAt)
	            .max()

	        let introducedEntries = firstReviewDaysBySourceID.compactMap { sourceID, introducedDay -> IntroducedVocabularyEntry? in
	            guard let card = introducedCardsBySourceID[sourceID] else { return nil }
	            return IntroducedVocabularyEntry(
	                introducedDay: introducedDay,
	                card: card,
	                reviews: reviewEventsBySourceID[sourceID] ?? [],
	                stateEvents: stateEventsBySourceID[sourceID] ?? [],
	                inferredLegacySuspendedAt: inferredLegacySuspendedAt
	            )
	        }

        guard !introducedEntries.isEmpty else { return [] }

        return days.flatMap { day -> [VocabularyPoint] in
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let referenceDate = min(nextDay.addingTimeInterval(-1), now)
            let entriesByBucket = Dictionary(grouping: introducedEntries.filter { $0.introducedDay <= day }) { entry in
                entry.bucket(on: referenceDate, now: now)
            }
            return IntroducedVocabularyDueBucket.stackOrder.compactMap { bucket -> VocabularyPoint? in
                let count = entriesByBucket[bucket]?.count ?? 0
                guard count > 0 else { return nil }
                return VocabularyPoint(day: day, bucket: bucket, count: count)
            }
        }
    }

    private var accuracyPoints: [AccuracyPoint] {
        let grouped = Dictionary(grouping: reviews) { review in
            Calendar.current.startOfDay(for: review.reviewedAt)
        }

        return dateRange(from: grouped.keys.min(), to: Date()).compactMap { day in
            guard let dayReviews = grouped[day], !dayReviews.isEmpty else {
                return nil
            }
            let correct = dayReviews.filter(\.wasCorrect).count
            return AccuracyPoint(
                day: day,
                accuracy: Double(correct) / Double(dayReviews.count)
            )
        }
    }

    private var reviewMixSegments: [ReviewMixSegment] {
        var seenCardKeys = Set<String>()
        var countsByDayAndKind: [ReviewMixKey: Int] = [:]

        for review in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) {
            let kind = seenCardKeys.insert(review.cardKey).inserted ? "New" : "Review"
            let key = ReviewMixKey(day: Calendar.current.startOfDay(for: review.reviewedAt), kind: kind)
            countsByDayAndKind[key, default: 0] += 1
        }

        return countsByDayAndKind
            .map { key, count in ReviewMixSegment(day: key.day, kind: key.kind, count: count) }
            .sorted {
                if $0.day == $1.day { return $0.kind < $1.kind }
                return $0.day < $1.day
            }
    }

    private func dateRange(from startDate: Date?, to endDate: Date) -> [Date] {
        guard let startDate else { return [] }
        return dateRange(from: startDate, to: Calendar.current.startOfDay(for: endDate))
    }

    private func dateRange(from startDate: Date, to endDate: Date) -> [Date] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: endDate)
        let earliest = calendar.startOfDay(for: startDate)
        let start = calendar.date(byAdding: .day, value: -29, to: end).map { max($0, earliest) } ?? earliest

        var days: [Date] = []
        var day = start
        while day <= end {
            days.append(day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return days
    }
}

private struct ProgressMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct ForecastRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct EmptyChartMessage: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
	}
}

private struct IntroducedVocabularyLegend: View {
    private let columns = [
        GridItem(.adaptive(minimum: 74), spacing: 10, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(IntroducedVocabularyDueBucket.allCases, id: \.self) { bucket in
                HStack(spacing: 5) {
                    Circle()
                        .fill(bucket.color)
                        .frame(width: 8, height: 8)
                    Text(bucket.label)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

private struct ProgressSnapshot {
    var introducedVocabularyCount: Int
    var activeIntroducedCardCount: Int
    var suspendedCardCount: Int
    var frictionCardCount: Int
    var loadSheddingCandidateCount: Int
    var loadSheddingCandidateIDs: [UUID]
    var resumeSuspendedCardIDs: [UUID]
    var intakeForecast: NewCardIntakeForecast
    var reviewLoadForecast: [ReviewLoadForecastDay]
    var introducedVocabularyPoints: [VocabularyPoint]
    var accuracyPoints: [AccuracyPoint]
    var reviewMixSegments: [ReviewMixSegment]
}

private struct IntroducedVocabularyEntry {
    var introducedDay: Date
	var card: StudyCard
	var reviews: [ReviewEvent]
	var stateEvents: [CardStateEvent]
    var inferredLegacySuspendedAt: Date?

    func bucket(on referenceDate: Date, now: Date) -> IntroducedVocabularyDueBucket {
        if isSuspended(on: referenceDate) {
            return .suspended
        }

        let dueAt = dueAt(on: referenceDate, now: now)
        return IntroducedVocabularyDueBucket(dueAt: dueAt, isSuspended: false, now: referenceDate)
    }

	    private func isSuspended(on referenceDate: Date) -> Bool {
	        if let event = stateEvents.last(where: { $0.changedAt <= referenceDate }) {
	            return event.isSuspended
	        }

	        guard card.isSuspended else { return false }
	        let suspendedAt = card.suspendedAt ?? inferredLegacySuspendedAt ?? card.updatedAt
	        return suspendedAt <= referenceDate
	    }

    private func dueAt(on referenceDate: Date, now: Date) -> Date {
        if let review = reviews.last(where: { $0.reviewedAt <= referenceDate }),
           let scheduledDueAt = review.scheduledDueAt {
            return scheduledDueAt
        }

        if referenceDate >= now || reviews.last?.reviewedAt ?? .distantPast <= referenceDate {
            return card.dueAt
        }

        return referenceDate
    }
}

private enum IntroducedVocabularyDueBucket: String, CaseIterable {
    case due
    case oneDay
    case threeDays
    case sevenDays
    case fourWeeks
    case distant
    case suspended

    static let stackOrder: [IntroducedVocabularyDueBucket] = [
        .suspended,
        .due,
        .oneDay,
        .threeDays,
        .sevenDays,
        .fourWeeks,
        .distant,
    ]

    init(dueAt: Date, isSuspended: Bool, now: Date) {
        if isSuspended {
            self = .suspended
            return
        }

        let daysUntilDue = dueAt.timeIntervalSince(now) / (24 * 60 * 60)
        switch daysUntilDue {
        case ...0:
            self = .due
        case ..<1:
            self = .oneDay
        case ..<4:
            self = .threeDays
        case ..<8:
            self = .sevenDays
        case ..<29:
            self = .fourWeeks
        default:
            self = .distant
        }
    }

    var label: String {
        switch self {
        case .due: "Due"
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .sevenDays: "7 days"
        case .fourWeeks: "4 weeks"
        case .distant: "Distant"
        case .suspended: "Suspended"
        }
    }

    static var chartStyles: KeyValuePairs<String, Color> {
        [
            "Due": due.color,
            "1 day": oneDay.color,
            "3 days": threeDays.color,
            "7 days": sevenDays.color,
            "4 weeks": fourWeeks.color,
            "Distant": distant.color,
            "Suspended": suspended.color,
        ]
    }

    var color: Color {
        switch self {
        case .due: .red
        case .oneDay: .orange
        case .threeDays: .yellow
        case .sevenDays: .green
        case .fourWeeks: .teal
        case .distant: .blue
        case .suspended: .gray
        }
    }
}

private struct VocabularyPoint: Identifiable {
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(bucket.rawValue)" }
    var day: Date
    var bucket: IntroducedVocabularyDueBucket
    var count: Int
}

private struct AccuracyPoint: Identifiable {
    var id: Date { day }
    var day: Date
    var accuracy: Double
}

private struct ReviewMixSegment: Identifiable {
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(kind)" }
    var day: Date
    var kind: String
    var count: Int
}

private struct ReviewMixKey: Hashable {
    var day: Date
    var kind: String
}

private extension Date {
    func scheduleIntervalText(from start: Date) -> String {
        let seconds = timeIntervalSince(start)
        guard seconds > 0 else { return "now" }

        let minute: TimeInterval = 60
        let hour = minute * 60
        let day = hour * 24
        let week = day * 7
        let month = day * 30

        switch seconds {
        case ..<hour:
            return Self.intervalText(value: Int(ceil(seconds / minute)), unit: "min")
        case ..<day:
            return Self.intervalText(value: Int(ceil(seconds / hour)), unit: "hour")
        case ..<(week * 2):
            return Self.intervalText(value: Int(ceil(seconds / day)), unit: "day")
        case ..<month:
            return Self.intervalText(value: Int(ceil(seconds / week)), unit: "week")
        default:
            return Self.intervalText(value: Int(ceil(seconds / month)), unit: "month")
        }
    }

    private static func intervalText(value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

private struct SettingsViewContent: View {
    @Binding var learningPace: LearningPace
    @Binding var hanziScript: HanziScript
    @Binding var hanziTypeface: HanziTypeface

    var body: some View {
        Form {
            Section("Study") {
                Picker("Learning Pace", selection: $learningPace) {
                    ForEach(LearningPace.allCases) { pace in
                        Text(pace.title).tag(pace)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Hanzi") {
                Text(hanziScript.displayText(for: "学习 汉字"))
                    .font(hanziTypeface.displayFont(size: 42, script: hanziScript))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)

                Picker("Script", selection: $hanziScript) {
                    ForEach(HanziScript.allCases) { script in
                        Text(script.title).tag(script)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Typeface", selection: $hanziTypeface) {
                    ForEach(HanziTypeface.allCases) { typeface in
                        Text(typeface.title).tag(typeface)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Audio") {
                LabeledContent("Voice", value: "System Mandarin")
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            VocabularyNote.self,
            StudyCard.self,
            ReviewEvent.self,
            CardStateEvent.self,
            UserSettings.self,
            SeedInstall.self
        ], inMemory: true)
}
