import AVFoundation
import Charts
import SwiftData
import SwiftUI

struct ContentView: View {
    var seedError: Error?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyNote.sourceID) private var notes: [VocabularyNote]
    @Query(sort: \StudyCard.dueAt) private var cards: [StudyCard]
    @Query(sort: \ReviewEvent.reviewedAt, order: .reverse) private var reviews: [ReviewEvent]
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
    @State private var hasLivePlanChanged = false
    @State private var isServingPassActive = false

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
                    learningPace: settings?.learningPace ?? .balanced,
                    reduceActiveLoad: reduceActiveLoad,
                    resumeSuspendedCards: resumeSuspendedCards
                )
            }
            .tabItem { Label("Progress", systemImage: "chart.bar") }
            .tag(AppTab.progress)

            NavigationStack {
                SettingsViewContent(settings: settingsBinding)
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
    }

    private var settings: UserSettings? {
        settingsRecords.first
    }

    private var settingsBinding: Binding<LearningPace> {
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
                reviewedAt: $0.reviewedAt
            )
        }
    }

    private func currentDesiredRetention(now: Date) -> Double {
        AdaptiveSessionPolicy.desiredRetention(
            pace: settings?.learningPace ?? .balanced,
            forecastedReviewLoad: AdaptiveSessionPolicy.forecastedReviewLoad(
                from: sessionCandidates(),
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
        let now = Date()
        let duplicateCount = cards.filter {
            !$0.isSuspended && $0.cardKey == activeCard.cardKey
        }.count
        let lastGrade = lastGrade(for: activeCard)
        let explanation = CardSelectionExplainer.explanation(
            isNew: activeCard.fsrsCardData == nil,
            dueAt: activeCard.dueAt,
            duplicateCount: duplicateCount,
            lastGrade: lastGrade,
            now: now
        )
        let interactionMode = activeInteractionMode ?? interactionMode(for: activeCard)

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
                plannedServingCount: servingCounters.plannedTotal,
                hasLivePlanChanged: hasLivePlanChanged,
                unseenVocabularyCount: unseenVocabularyCount,
                explanation: explanation
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

    private func moveToNextCard(forceNewCards: Bool = false) {
        if forceNewCards {
            endServingPass()
        } else if isServingPassActive, servingCounters.total <= 0 {
            endServingPass()
            activeCardID = nil
            activeInteractionMode = nil
            activeChoiceSeed = UUID().uuidString
            selectedChoice = nil
            isAnswerRevealed = false
            return
        }

        let now = Date()
        let candidates = sessionCandidates()

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: candidates,
            pace: settings?.learningPace ?? .balanced,
            recentAccuracy: recentAccuracy,
            newCardsStudiedToday: newCardsStudiedToday,
            historicalReviewLoadPerNewCard: historicalReviewLoadPerNewCard,
            now: now,
            forceNewCards: forceNewCards
        )

        let selectedCandidate = AdaptiveSessionPolicy.nextCandidate(
            from: decision.orderedCards,
            recentCardIDs: Array(recentCardIDs.suffix(3)),
            recentNoteSourceIDs: Array(recentNoteSourceIDs.suffix(2))
        )

        activeCardID = selectedCandidate?.id
        if let selectedCandidate,
           let selectedCard = cards.first(where: { $0.id == selectedCandidate.id }) {
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
            startServingPass(with: decision.orderedCards)
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
            hasLivePlanChanged = true
        }
    }

    private func endServingPass() {
        servingCounters = ServingCounters()
        servingPlannedCardIDs = []
        hasLivePlanChanged = false
        isServingPassActive = false
    }

    private func startServingPass(with cards: [SessionCardCandidate]) {
        servingCounters = ServingCounters(cards: cards)
        servingPlannedCardIDs = Set(cards.map(\.id))
        hasLivePlanChanged = false
        isServingPassActive = true
    }

    private func sessionCandidates() -> [SessionCardCandidate] {
        cards
            .filter { !$0.isSuspended }
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    recentLapses: recentLapses(for: card.cardKey),
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
    }

    private func continuePastNaturalStop() {
        moveToNextCard(forceNewCards: true)
    }

    private func recentLapses(for cardKey: String) -> Int {
        reviews
            .filter { $0.cardKey == cardKey && $0.gradeRaw == ReviewGrade.again.rawValue }
            .prefix(12)
            .count
    }

    private var suspendedCardCount: Int {
        cards.filter(\.isSuspended).count
    }

    private var loadSheddingCandidateIDs: [UUID] {
        LoadSheddingPolicy.cardIDsToSuspend(
            cards: loadSheddingCards,
            reviews: loadSheddingReviews,
            now: Date()
        )
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

    private func reduceActiveLoad() {
        let idsToSuspend = Set(loadSheddingCandidateIDs)
        guard !idsToSuspend.isEmpty else { return }

        let now = Date()
        for card in cards where idsToSuspend.contains(card.id) {
            card.isSuspended = true
            card.updatedAt = now
        }

        try? modelContext.save()
        endServingPass()
        if let activeCardID, idsToSuspend.contains(activeCardID) {
            self.activeCardID = nil
        }
        moveToNextCard()
    }

    private func resumeSuspendedCards() {
        let now = Date()
        let suspendedBatch = cards
            .filter(\.isSuspended)
            .sorted {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                return $0.cardKey < $1.cardKey
            }
            .prefix(12)

        guard !suspendedBatch.isEmpty else { return }

        for card in suspendedBatch {
            card.isSuspended = false
            card.updatedAt = now
        }

        try? modelContext.save()
        endServingPass()
        moveToNextCard()
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
            let review = try FSRSReviewScheduler.review(
                cardData: card.fsrsCardData,
                grade: grade,
                desiredRetention: currentDesiredRetention(now: now),
                now: now
            )
            card.fsrsCardData = review.cardData
            card.dueAt = review.dueAt
            card.updatedAt = now

            modelContext.insert(
                ReviewEvent(
                    cardKey: card.cardKey,
                    noteSourceID: note.sourceID,
                    grade: grade,
                    interaction: interaction,
                    wasCorrect: wasCorrect,
                    responseSeconds: responseSeconds
                )
            )
            try modelContext.save()
            servingCounters.consumeReview(
                cardID: card.id,
                noteSourceID: note.sourceID,
                wasNew: wasServingNewCard,
                grade: grade,
                scheduledDueAt: review.dueAt,
                now: now
            )
            if advanceImmediately {
                moveToNextCard()
            }
        } catch {
            isAnswerRevealed = true
        }
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
        speechSynthesizer.speak(mandarinUtterance(for: note.hanzi))
    }

    private func prepareSpeech(for note: VocabularyNote?) {
        guard let note else { return }
        _ = cachedMandarinVoice()
        warmSpeechSynthesizerIfNeeded(with: note.hanzi)
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
    var plannedServingCount: Int
    var hasLivePlanChanged: Bool
    var unseenVocabularyCount: Int
    var explanation: CardSelectionExplanation
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
                plannedServingCount: prompt.plannedServingCount,
                hasLivePlanChanged: prompt.hasLivePlanChanged,
                unseenVocabularyCount: prompt.unseenVocabularyCount,
                explanation: prompt.explanation
            )

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Text(prompt.note.hanzi)
                    .font(.system(size: 116, weight: .semibold, design: .serif))
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Hanzi \(prompt.note.hanzi)")

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
    var plannedServingCount: Int
    var hasLivePlanChanged: Bool
    var unseenVocabularyCount: Int
    var explanation: CardSelectionExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(servingCount) live · \(servingNewCount) new · \(servingReviewCount) review · \(unseenVocabularyCount) unseen")
                Spacer()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(explanation.title)
                        .fontWeight(.semibold)
                    Text("·")
                    Text(explanation.detail)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(explanation.title)
                        .fontWeight(.semibold)
                    Text(explanation.detail)
                }
            }

            if hasLivePlanChanged {
                Text("This pass started with \(plannedServingCount); \(servingCount) remain after completed cards and returned reviews.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

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
    var learningPace: LearningPace
    var reduceActiveLoad: () -> Void
    var resumeSuspendedCards: () -> Void

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
                        value: "\(snapshot.loadSheddingCandidateCount)",
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
                    reduceActiveLoad()
                } label: {
                    Label("Reduce active load", systemImage: "tray.and.arrow.down")
                }
                .disabled(snapshot.loadSheddingCandidateCount == 0)

                if snapshot.suspendedCardCount > 0 {
                    Button {
                        resumeSuspendedCards()
                    } label: {
                        Label("Resume 12 suspended", systemImage: "arrow.uturn.up")
                    }
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
                        AreaMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Introduced", point.count)
                        )
                        .foregroundStyle(.green.opacity(0.16))

                        LineMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Introduced", point.count)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.stepEnd)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Introduced vocabulary over time")
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
        let candidates = cards
            .filter { !$0.isSuspended }
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    recentLapses: recentAgainCounts[card.cardKey] ?? 0,
                    noteSourceID: card.noteSourceID,
                    kind: card.kind
                )
            }
        let reviewHistoryEvents = reviews.map {
            ReviewHistoryEvent(
                cardKey: $0.cardKey,
                noteSourceID: $0.noteSourceID,
                reviewedAt: $0.reviewedAt
            )
        }
        let recentAccuracy = recentAccuracy
        let newCardsStudiedToday = newCardsStudiedToday
        let intakeForecast = AdaptiveSessionPolicy.newCardIntakeForecast(
            from: candidates,
            pace: learningPace,
            recentAccuracy: recentAccuracy,
            newCardsStudiedToday: newCardsStudiedToday,
            historicalReviewLoadPerNewCard: AdaptiveSessionPolicy.historicalReviewLoadPerNewCard(
                from: reviewHistoryEvents,
                now: now
            ),
            now: now
        )
        let loadSheddingCandidateCount = LoadSheddingPolicy.cardIDsToSuspend(
            cards: loadSheddingCards,
            reviews: loadSheddingReviews,
            now: now
        ).count

        return ProgressSnapshot(
            introducedVocabularyCount: Set(reviews.map(\.noteSourceID).filter { !$0.isEmpty }).count,
            activeIntroducedCardCount: cards.filter { !$0.isSuspended && $0.fsrsCardData != nil }.count,
            suspendedCardCount: cards.filter(\.isSuspended).count,
            loadSheddingCandidateCount: loadSheddingCandidateCount,
            intakeForecast: intakeForecast,
            reviewLoadForecast: AdaptiveSessionPolicy.reviewLoadForecastByDay(from: candidates, now: now),
            introducedVocabularyPoints: introducedVocabularyPoints,
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

    private var introducedVocabularyPoints: [VocabularyPoint] {
        guard !reviews.isEmpty else { return [] }

        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let earliest = reviews
            .map { calendar.startOfDay(for: $0.reviewedAt) }
            .min() ?? end
        let lastThirtyDays = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        let minimumWindowStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let start = min(max(earliest, lastThirtyDays), minimumWindowStart)
        let days = dateRange(from: start, to: end)
        let firstReviewDays = Dictionary(grouping: reviews.filter { !$0.noteSourceID.isEmpty }, by: \.noteSourceID)
            .values
            .compactMap { noteReviews in
                noteReviews.map(\.reviewedAt).min().map { calendar.startOfDay(for: $0) }
            }
            .sorted()
        var introducedIndex = 0

        return days.map { day in
            while introducedIndex < firstReviewDays.count, firstReviewDays[introducedIndex] <= day {
                introducedIndex += 1
            }
            return VocabularyPoint(day: day, count: introducedIndex)
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

private struct ProgressSnapshot {
    var introducedVocabularyCount: Int
    var activeIntroducedCardCount: Int
    var suspendedCardCount: Int
    var loadSheddingCandidateCount: Int
    var intakeForecast: NewCardIntakeForecast
    var reviewLoadForecast: [ReviewLoadForecastDay]
    var introducedVocabularyPoints: [VocabularyPoint]
    var accuracyPoints: [AccuracyPoint]
    var reviewMixSegments: [ReviewMixSegment]
}

private struct VocabularyPoint: Identifiable {
    var id: Date { day }
    var day: Date
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

private struct SettingsViewContent: View {
    @Binding var settings: LearningPace

    var body: some View {
        Form {
            Section("Study") {
                Picker("Learning Pace", selection: $settings) {
                    ForEach(LearningPace.allCases) { pace in
                        Text(pace.title).tag(pace)
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
            UserSettings.self,
            SeedInstall.self
        ], inMemory: true)
}
