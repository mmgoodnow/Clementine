import Foundation
import SwiftData

@Model
final class VocabularyNote {
    @Attribute(.unique) var sourceID: String = ""
    var id: UUID = UUID()
    var deckID: String = ""
    var hanzi: String = ""
    var pinyin: String = ""
    var english: String = ""
    var lesson: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        sourceID: String,
        deckID: String,
        hanzi: String,
        pinyin: String,
        english: String,
        lesson: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.deckID = deckID
        self.hanzi = hanzi
        self.pinyin = pinyin
        self.english = english
        self.lesson = lesson
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class StudyCard {
    @Attribute(.unique) var cardKey: String = ""
    var id: UUID = UUID()
    var noteSourceID: String = ""
    var kindRaw: String = CardKind.hanziToMeaning.rawValue
    var dueAt: Date = Date()
    var fsrsCardData: Data?
    var isSuspended: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        noteSourceID: String,
        kind: CardKind,
        dueAt: Date = Date(),
        fsrsCardData: Data? = nil
    ) {
        self.noteSourceID = noteSourceID
        self.kindRaw = kind.rawValue
        self.cardKey = "\(noteSourceID)#\(kind.rawValue)"
        self.dueAt = dueAt
        self.fsrsCardData = fsrsCardData
    }

    var kind: CardKind {
        get { CardKind(rawValue: kindRaw) ?? .hanziToMeaning }
        set {
            kindRaw = newValue.rawValue
            cardKey = "\(noteSourceID)#\(newValue.rawValue)"
        }
    }
}

@Model
final class ReviewEvent {
    var id: UUID = UUID()
    var cardKey: String = ""
    var noteSourceID: String = ""
    var gradeRaw: String = ReviewGrade.good.rawValue
    var interactionRaw: String = ReviewInteraction.multipleChoice.rawValue
    var reviewedAt: Date = Date()
    var wasCorrect: Bool = true
    var responseSeconds: Double = 0

    init(
        cardKey: String,
        noteSourceID: String,
        grade: ReviewGrade,
        interaction: ReviewInteraction,
        reviewedAt: Date = Date(),
        wasCorrect: Bool,
        responseSeconds: Double
    ) {
        self.cardKey = cardKey
        self.noteSourceID = noteSourceID
        self.gradeRaw = grade.rawValue
        self.interactionRaw = interaction.rawValue
        self.reviewedAt = reviewedAt
        self.wasCorrect = wasCorrect
        self.responseSeconds = responseSeconds
    }
}

@Model
final class UserSettings {
    @Attribute(.unique) var singletonID: String = "default"
    var learningPaceRaw: String = LearningPace.balanced.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(learningPace: LearningPace = .balanced) {
        self.learningPaceRaw = learningPace.rawValue
    }

    var learningPace: LearningPace {
        get { LearningPace(rawValue: learningPaceRaw) ?? .balanced }
        set {
            learningPaceRaw = newValue.rawValue
            updatedAt = Date()
        }
    }
}

@Model
final class SeedInstall {
    @Attribute(.unique) var deckID: String = ""
    var version: Int = 0
    var installedAt: Date = Date()

    init(deckID: String, version: Int, installedAt: Date = Date()) {
        self.deckID = deckID
        self.version = version
        self.installedAt = installedAt
    }
}
