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
                let orderedDueAt = now.addingTimeInterval(Double(kind.studyOrder * 10_000 + order))
                context.insert(StudyCard(noteSourceID: item.sourceID, kind: kind, dueAt: orderedDueAt))
            }
        }
    }
}

@MainActor
enum SeedDeduplicator {
    @discardableResult
    static func removeDuplicateSeedRecords(context: ModelContext) throws -> Int {
        var removedCount = 0
        removedCount += try removeDuplicateNotes(context: context)
        removedCount += try removeDuplicateCards(context: context)

        if removedCount > 0 {
            try context.save()
        }
        return removedCount
    }

    private static func removeDuplicateNotes(context: ModelContext) throws -> Int {
        let notes = try context.fetch(FetchDescriptor<VocabularyNote>())
        let grouped = Dictionary(grouping: notes.filter { !$0.sourceID.isEmpty }, by: \.sourceID)
        var removedCount = 0

        for duplicates in grouped.values where duplicates.count > 1 {
            let ordered = duplicates.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.createdAt < $1.createdAt
            }
            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                removedCount += 1
            }
        }

        return removedCount
    }

    private static func removeDuplicateCards(context: ModelContext) throws -> Int {
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let grouped = Dictionary(grouping: cards.filter { !$0.cardKey.isEmpty }, by: \.cardKey)
        var removedCount = 0

        for duplicates in grouped.values where duplicates.count > 1 {
            let ordered = duplicates.sorted(by: preferredCard(_:_:))
            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                removedCount += 1
            }
        }

        return removedCount
    }

    private static func preferredCard(_ lhs: StudyCard, _ rhs: StudyCard) -> Bool {
        let lhsHasProgress = lhs.fsrsCardData != nil
        let rhsHasProgress = rhs.fsrsCardData != nil
        if lhsHasProgress != rhsHasProgress { return lhsHasProgress }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
