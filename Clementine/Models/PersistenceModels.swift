import Foundation
import SwiftData

@Model
final class VocabularyNote {
    var sourceID: String = ""
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
    var cardKey: String = ""
    var id: UUID = UUID()
    var noteSourceID: String = ""
    var kindRaw: String = CardKind.hanziToMeaning.rawValue
    var dueAt: Date = Date()
    var fsrsCardData: Data?
    var isSuspended: Bool = false
    var suspendedAt: Date?
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
    var scheduledDueAt: Date?
    var wasCorrect: Bool = true
    var responseSeconds: Double = 0

    init(
        cardKey: String,
        noteSourceID: String,
        grade: ReviewGrade,
        interaction: ReviewInteraction,
        reviewedAt: Date = Date(),
        scheduledDueAt: Date? = nil,
        wasCorrect: Bool,
        responseSeconds: Double
    ) {
        self.cardKey = cardKey
        self.noteSourceID = noteSourceID
        self.gradeRaw = grade.rawValue
        self.interactionRaw = interaction.rawValue
        self.reviewedAt = reviewedAt
        self.scheduledDueAt = scheduledDueAt
        self.wasCorrect = wasCorrect
        self.responseSeconds = responseSeconds
    }
}

@Model
final class CardStateEvent {
    var id: UUID = UUID()
    var cardKey: String = ""
    var noteSourceID: String = ""
    var changedAt: Date = Date()
    var isSuspended: Bool = false

    init(
        cardKey: String,
        noteSourceID: String,
        changedAt: Date = Date(),
        isSuspended: Bool
    ) {
        self.cardKey = cardKey
        self.noteSourceID = noteSourceID
        self.changedAt = changedAt
        self.isSuspended = isSuspended
    }
}

@Model
final class UserSettings {
    var singletonID: String = "default"
    var learningPaceRaw: String = LearningPace.balanced.rawValue
    var hanziScriptRaw: String = HanziScript.simplified.rawValue
    var hanziTypefaceRaw: String = HanziTypeface.serif.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        learningPace: LearningPace = .balanced,
        hanziScript: HanziScript = .simplified,
        hanziTypeface: HanziTypeface = .serif
    ) {
        self.learningPaceRaw = learningPace.rawValue
        self.hanziScriptRaw = hanziScript.rawValue
        self.hanziTypefaceRaw = hanziTypeface.rawValue
    }

    var learningPace: LearningPace {
        get { LearningPace(rawValue: learningPaceRaw) ?? .balanced }
        set {
            learningPaceRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var hanziScript: HanziScript {
        get { HanziScript(rawValue: hanziScriptRaw) ?? .simplified }
        set {
            hanziScriptRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var hanziTypeface: HanziTypeface {
        get { HanziTypeface(rawValue: hanziTypefaceRaw) ?? .serif }
        set {
            hanziTypefaceRaw = newValue.rawValue
            updatedAt = Date()
        }
    }
}

@Model
final class SeedInstall {
    var deckID: String = ""
    var version: Int = 0
    var installedAt: Date = Date()

    init(deckID: String, version: Int, installedAt: Date = Date()) {
        self.deckID = deckID
        self.version = version
        self.installedAt = installedAt
    }
}
