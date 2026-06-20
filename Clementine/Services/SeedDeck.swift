import Foundation
import SwiftData

struct SeedDeck: Decodable, Equatable {
    var deckID: String
    var version: Int
    var items: [SeedVocabularyItem]
}

struct SeedVocabularyItem: Decodable, Equatable {
    var sourceID: String
    var hanzi: String
    var pinyin: String
    var english: String
    var lesson: String?
}

enum SeedDeckLoader {
    static func bundledHSK2Deck() throws -> SeedDeck {
        guard let url = Bundle.main.url(forResource: "hsk2-seed", withExtension: "json") else {
            throw SeedDeckError.missingResource
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SeedDeck.self, from: data)
    }
}

enum SeedDeckError: Error {
    case missingResource
}

@MainActor
enum SeedImporter {
    static func installIfNeeded(deck: SeedDeck, context: ModelContext, now: Date = Date()) throws {
        let deckID = deck.deckID
        let installDescriptor = FetchDescriptor<SeedInstall>(
            predicate: #Predicate { $0.deckID == deckID }
        )
        let existingInstall = try context.fetch(installDescriptor).first
        guard existingInstall?.version != deck.version else { return }

        for (index, item) in deck.items.enumerated() {
            try upsertNote(item: item, deckID: deck.deckID, context: context, now: now)
            try ensureCards(for: item, context: context, now: now, order: index)
        }

        if let existingInstall {
            existingInstall.version = deck.version
            existingInstall.installedAt = now
        } else {
            context.insert(SeedInstall(deckID: deck.deckID, version: deck.version, installedAt: now))
        }

        try context.save()
    }

    private static func upsertNote(
        item: SeedVocabularyItem,
        deckID: String,
        context: ModelContext,
        now: Date
    ) throws {
        let sourceID = item.sourceID
        let descriptor = FetchDescriptor<VocabularyNote>(
            predicate: #Predicate { $0.sourceID == sourceID }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.deckID = deckID
            existing.hanzi = item.hanzi
            existing.pinyin = item.pinyin
            existing.english = item.english
            existing.lesson = item.lesson
            existing.updatedAt = now
        } else {
            context.insert(
                VocabularyNote(
                    sourceID: item.sourceID,
                    deckID: deckID,
                    hanzi: item.hanzi,
                    pinyin: item.pinyin,
                    english: item.english,
                    lesson: item.lesson,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
    }

    private static func ensureCards(
        for item: SeedVocabularyItem,
        context: ModelContext,
        now: Date,
        order: Int
    ) throws {
        for kind in [CardKind.hanziToMeaning, .hanziToPinyin, .recall] {
            let cardKey = "\(item.sourceID)#\(kind.rawValue)"
            let descriptor = FetchDescriptor<StudyCard>(
                predicate: #Predicate { $0.cardKey == cardKey }
            )

            if try context.fetch(descriptor).isEmpty {
                let orderedDueAt = now.addingTimeInterval(Double(order))
                context.insert(StudyCard(noteSourceID: item.sourceID, kind: kind, dueAt: orderedDueAt))
            }
        }
    }
}
