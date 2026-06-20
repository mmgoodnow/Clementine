import AVFoundation
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
                    continueSession: moveToNextCard
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
            moveToNextCard()
        }
        .onChange(of: cards.count) { _, _ in
            if activeCard == nil {
                moveToNextCard()
            }
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

    private func moveToNextCard() {
        let now = Date()
        let candidates = cards
            .filter { !$0.isSuspended }
            .map { card in
                SessionCardCandidate(
                    id: card.id,
                    dueAt: card.dueAt,
                    isNew: card.fsrsCardData == nil,
                    recentLapses: recentLapses(for: card.cardKey)
                )
            }

        let decision = AdaptiveSessionPolicy.chooseCards(
            from: candidates,
            pace: settings?.learningPace ?? .balanced,
            recentAccuracy: recentAccuracy,
            now: now
        )

        activeCardKey = decision.orderedCards.first.flatMap { candidate in
            cards.first { $0.id == candidate.id }?.cardKey
        }
        selectedChoice = nil
        isAnswerRevealed = false
        responseStartedAt = now
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

        return Array(([correct] + pool).prefix(4)).shuffled()
    }

    private func correctAnswer(for card: StudyCard, note: VocabularyNote) -> String {
        card.kind == .hanziToPinyin ? note.pinyin : note.english
    }

    private func chooseAnswer(_ answer: String) {
        guard let activeCard, let activeNote else { return }
        let correct = answer == correctAnswer(for: activeCard, note: activeNote)
        let elapsed = Date().timeIntervalSince(responseStartedAt)
        let grade = ReviewGradeMapper.multipleChoice(correct: correct, responseSeconds: elapsed)
        applyReview(card: activeCard, note: activeNote, grade: grade, wasCorrect: correct, interaction: .multipleChoice, responseSeconds: elapsed)
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
        responseSeconds: Double
    ) {
        do {
            let review = try FSRSReviewScheduler.review(cardData: card.fsrsCardData, grade: grade)
            card.fsrsCardData = review.cardData
            card.dueAt = review.dueAt
            card.updatedAt = Date()

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
            moveToNextCard()
        } catch {
            isAnswerRevealed = true
        }
    }

    private func speak(_ note: VocabularyNote) {
        let utterance = AVSpeechUtterance(string: note.hanzi)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.82
        speechSynthesizer.speak(utterance)
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
            Rectangle()
                .fill(ClementineTheme.background)
                .ignoresSafeArea()

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
            Label("\(dueCount)", systemImage: "clock")
            Label("\(newCount)", systemImage: "sparkle")
            Spacer()
            Text(kind.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
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
                    Text(choice)
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(selectedChoice != nil)
            }
        }
    }
}

private struct RecallControls: View {
    var note: VocabularyNote
    @Binding var isAnswerRevealed: Bool
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

                HStack {
                    Button("Missed") { gradeRecall(false, false) }
                    Button("Hard") { gradeRecall(true, false) }
                    Button("Got it") { gradeRecall(true, true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else {
                Text("Recall the pinyin and meaning")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button {
                    isAnswerRevealed = true
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
            Section("Deck") {
                LabeledContent("Vocabulary", value: "\(notes.count)")
                LabeledContent("Cards", value: "\(cards.count)")
                LabeledContent("Reviewed", value: "\(reviews.count)")
            }

            Section("Sync") {
                LabeledContent("Store", value: "iCloud Private Database")
                LabeledContent("Container", value: ClementineModelContainer.iCloudContainerIdentifier)
            }
        }
        .navigationTitle("Progress")
    }
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

private enum ClementineTheme {
    static var background: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.97, blue: 0.94),
                Color(red: 0.93, green: 0.96, blue: 0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
