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
    @State private var activeCardKey: String?
    @State private var selectedChoice: String?
    @State private var isAnswerRevealed = false
    @State private var responseStartedAt = Date()
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var recentCardIDs: [UUID] = []
    @State private var recentNoteSourceIDs: [String] = []

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
                    gradeRecall: gradeRecall,
                    continueSession: continuePastNaturalStop
                )
            }
            .tabItem { Label("Study", systemImage: "character.book.closed") }
            .tag(AppTab.study)

            NavigationStack {
                ProgressViewContent(notes: notes, cards: cards, reviews: reviews)
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
        guard let activeCardKey else { return nil }
        return cards.first { $0.cardKey == activeCardKey }
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

        let dueCount = cards.filter { !$0.isSuspended && $0.fsrsCardData != nil && $0.dueAt <= Date() }.count
        let newCount = cards.filter { !$0.isSuspended && $0.fsrsCardData == nil }.count

        return .card(
            StudyPrompt(
                note: activeNote,
                card: activeCard,
                correctAnswer: correctAnswer(for: activeCard, note: activeNote),
                choices: choices(for: activeCard, note: activeNote),
                dueCount: dueCount,
                newCount: newCount
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
        let now = Date()
        let candidates = sessionCandidates()

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: candidates,
            pace: settings?.learningPace ?? .balanced,
            recentAccuracy: recentAccuracy,
            now: now,
            forceNewCards: forceNewCards
        )

        let selectedCandidate = AdaptiveSessionPolicy.nextCandidate(
            from: decision.orderedCards,
            recentCardIDs: Array(recentCardIDs.suffix(3)),
            recentNoteSourceIDs: Array(recentNoteSourceIDs.suffix(2))
        )

        activeCardKey = selectedCandidate.flatMap { candidate in
            cards.first { $0.id == candidate.id }?.cardKey
        }
        if let selectedCandidate {
            rememberShown(candidate: selectedCandidate)
        }
        selectedChoice = nil
        isAnswerRevealed = false
        responseStartedAt = now
    }

    private func rememberShown(candidate: SessionCardCandidate) {
        recentCardIDs.append(candidate.id)
        recentCardIDs = Array(recentCardIDs.suffix(6))
        if !candidate.noteSourceID.isEmpty {
            recentNoteSourceIDs.append(candidate.noteSourceID)
            recentNoteSourceIDs = Array(recentNoteSourceIDs.suffix(4))
        }
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
            .prefix(30)
            .filter { $0.cardKey == cardKey && $0.gradeRaw == ReviewGrade.again.rawValue }
            .count
    }

    private func choices(for card: StudyCard, note: VocabularyNote) -> [String] {
        let correct = correctAnswer(for: card, note: note)
        let pool = notes
            .map { card.kind == .hanziToPinyin ? $0.pinyin : $0.english }
            .filter { $0 != correct }
        let preferredSyllableCount = card.kind == .hanziToPinyin
            ? MultipleChoiceBuilder.pinyinSyllableCount(correct)
            : nil

        return MultipleChoiceBuilder.choices(
            correctAnswer: correct,
            distractorPool: pool,
            seed: card.cardKey,
            preferredSyllableCount: preferredSyllableCount
        )
    }

    private func correctAnswer(for card: StudyCard, note: VocabularyNote) -> String {
        card.kind == .hanziToPinyin ? note.pinyin : note.english
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
        scheduleMultipleChoiceAdvance(cardKey: activeCard.cardKey, selectedAnswer: answer)
    }

    private func gradeRecall(remembered: Bool, confident: Bool) {
        guard let activeCard, let activeNote else { return }
        let elapsed = Date().timeIntervalSince(responseStartedAt)
        let grade = ReviewGradeMapper.recall(remembered: remembered, confident: confident)
        applyReview(card: activeCard, note: activeNote, grade: grade, wasCorrect: remembered, interaction: .recall, responseSeconds: elapsed)
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
            if advanceImmediately {
                moveToNextCard()
            }
        } catch {
            isAnswerRevealed = true
        }
    }

    private func scheduleMultipleChoiceAdvance(cardKey: String, selectedAnswer: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            guard activeCardKey == cardKey, selectedChoice == selectedAnswer else { return }
            moveToNextCard()
        }
    }

    private func speak(_ note: VocabularyNote) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: note.hanzi)
        utterance.voice = preferredMandarinVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        speechSynthesizer.speak(utterance)
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
    var dueCount: Int
    var newCount: Int
}

private struct StudyView: View {
    var state: StudyScreenState
    @Binding var selectedChoice: String?
    @Binding var isAnswerRevealed: Bool
    var seedError: Error?
    var speak: (VocabularyNote) -> Void
    var chooseAnswer: (String) -> Void
    var gradeRecall: (Bool, Bool) -> Void
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
                    gradeRecall: gradeRecall
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
    var gradeRecall: (Bool, Bool) -> Void

    var body: some View {
        VStack(spacing: 22) {
            StudyStatusBar(dueCount: prompt.dueCount, newCount: prompt.newCount, kind: prompt.card.kind)

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

            if prompt.card.kind == .recall {
                RecallControls(
                    note: prompt.note,
                    isAnswerRevealed: $isAnswerRevealed,
                    speak: speak,
                    gradeRecall: gradeRecall
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
    var dueCount: Int
    var newCount: Int
    var kind: CardKind

    var body: some View {
        HStack(spacing: 10) {
            Text("\(dueCount) due · \(newCount) new · \(kind.title)")
            Spacer()
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
                    selectedChoice = choice
                    chooseAnswer(choice)
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

            if let selectedChoice, selectedChoice != prompt.correctAnswer {
                Label("Correct answer: \(prompt.correctAnswer)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
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

private struct RecallControls: View {
    var note: VocabularyNote
    @Binding var isAnswerRevealed: Bool
    var speak: (VocabularyNote) -> Void
    var gradeRecall: (Bool, Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isAnswerRevealed {
                VStack(spacing: 6) {
                    Text(note.pinyin)
                        .font(.title2.weight(.semibold))
                    Text(note.english)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        RecallGradeButton(
                            title: "Missed",
                            systemImage: "xmark",
                            prominence: .secondary
                        ) {
                            gradeRecall(false, false)
                        }

                        RecallGradeButton(
                            title: "Hard",
                            systemImage: "exclamationmark",
                            prominence: .secondary
                        ) {
                            gradeRecall(true, false)
                        }

                        RecallGradeButton(
                            title: "Got it",
                            systemImage: "checkmark",
                            prominence: .primary
                        ) {
                            gradeRecall(true, true)
                        }
                    }

                    VStack(spacing: 10) {
                        RecallGradeButton(
                            title: "Missed",
                            systemImage: "xmark",
                            prominence: .secondary
                        ) {
                            gradeRecall(false, false)
                        }

                        RecallGradeButton(
                            title: "Hard",
                            systemImage: "exclamationmark",
                            prominence: .secondary
                        ) {
                            gradeRecall(true, false)
                        }

                        RecallGradeButton(
                            title: "Got it",
                            systemImage: "checkmark",
                            prominence: .primary
                        ) {
                            gradeRecall(true, true)
                        }
                    }
                }
                .controlSize(.large)
            } else {
                Text("Recall the pinyin and meaning")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button {
                    isAnswerRevealed = true
                    speak(note)
                } label: {
                    Label("Reveal", systemImage: "eye")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
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
                .frame(minWidth: 104, maxWidth: .infinity, minHeight: 44)
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

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ProgressMetric(title: "Vocabulary", value: "\(notes.count)", systemImage: "character.book.closed")
                    ProgressMetric(title: "Cards", value: "\(cards.count)", systemImage: "rectangle.stack")
                    ProgressMetric(title: "Reviews", value: "\(reviews.count)", systemImage: "checkmark.circle")
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Vocabulary") {
                if vocabularyPoints.isEmpty {
                    EmptyChartMessage(text: "Vocabulary growth will appear after the deck is installed.")
                } else {
                    Chart(vocabularyPoints) { point in
                        AreaMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Vocabulary", point.count)
                        )
                        .foregroundStyle(.green.opacity(0.16))

                        LineMark(
                            x: .value("Day", point.day, unit: .day),
                            y: .value("Vocabulary", point.count)
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.stepEnd)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Vocabulary over time")
                }
            }

            Section("Accuracy") {
                if accuracyPoints.isEmpty {
                    EmptyChartMessage(text: "Accuracy will appear after reviews.")
                } else {
                    Chart(accuracyPoints) { point in
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
                if reviewMixSegments.isEmpty {
                    EmptyChartMessage(text: "New and review mix will appear after reviews.")
                } else {
                    Chart(reviewMixSegments) { segment in
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

    private var vocabularyPoints: [VocabularyPoint] {
        guard !notes.isEmpty else { return [] }

        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let earliest = notes
            .map { calendar.startOfDay(for: $0.createdAt) }
            .min() ?? end
        let lastThirtyDays = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        let minimumWindowStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let start = min(max(earliest, lastThirtyDays), minimumWindowStart)
        let days = dateRange(from: start, to: end)
        let noteDays = notes
            .map { calendar.startOfDay(for: $0.createdAt) }
            .sorted()
        var noteIndex = 0

        return days.map { day in
            while noteIndex < noteDays.count, noteDays[noteIndex] <= day {
                noteIndex += 1
            }
            return VocabularyPoint(day: day, count: noteIndex)
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

private struct EmptyChartMessage: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
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
