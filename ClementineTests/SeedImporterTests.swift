@testable import Clementine
import SwiftData
import XCTest

@MainActor
final class SeedImporterTests: XCTestCase {
    func testSeedImportIsIdempotentAndPreservesStableKeys() throws {
        let container = try ClementineModelContainer.make(inMemory: true)
        let context = container.mainContext
        let deck = SeedDeck(
            deckID: "test",
            version: 1,
            items: [
                SeedVocabularyItem(
                    sourceID: "test-1",
                    hanzi: "爱",
                    pinyin: "ài",
                    english: "love",
                    lesson: "Core"
                )
            ]
        )

        try SeedImporter.installIfNeeded(deck: deck, context: context)
        try SeedImporter.installIfNeeded(deck: deck, context: context)

        let notes = try context.fetch(FetchDescriptor<VocabularyNote>())
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let installs = try context.fetch(FetchDescriptor<SeedInstall>())

        XCTAssertEqual(notes.map(\.sourceID), ["test-1"])
        XCTAssertEqual(cards.map(\.cardKey), ["test-1#hanziToMeaning"])
        XCTAssertEqual(cards.map(\.kind), [.hanziToMeaning])
        XCTAssertEqual(installs.map(\.deckID), ["test"])
    }

    func testSeedImportCreatesOneCanonicalCardPerVocabularyInDeckOrder() throws {
        let container = try ClementineModelContainer.make(inMemory: true)
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_000)
        let deck = SeedDeck(
            deckID: "test",
            version: 1,
            items: [
                SeedVocabularyItem(sourceID: "test-1", hanzi: "爱", pinyin: "ài", english: "love", lesson: "HSK 1"),
                SeedVocabularyItem(sourceID: "test-2", hanzi: "吧", pinyin: "ba", english: "suggestion particle", lesson: "HSK 2"),
                SeedVocabularyItem(sourceID: "test-3", hanzi: "阿姨", pinyin: "āyí", english: "aunt", lesson: "HSK 3")
            ]
        )

        try SeedImporter.installIfNeeded(deck: deck, context: context, now: now)

        let cards = try context.fetch(FetchDescriptor<StudyCard>()).sorted { lhs, rhs in
            if lhs.dueAt == rhs.dueAt { return lhs.cardKey < rhs.cardKey }
            return lhs.dueAt < rhs.dueAt
        }

        XCTAssertEqual(cards.map(\.noteSourceID), ["test-1", "test-2", "test-3"])
        XCTAssertEqual(cards.map(\.kind), [.hanziToMeaning, .hanziToMeaning, .hanziToMeaning])
        XCTAssertEqual(cards.map(\.cardKey), [
            "test-1#hanziToMeaning",
            "test-2#hanziToMeaning",
            "test-3#hanziToMeaning",
        ])
    }

    func testDeduplicatorRemovesCloudKitMergedSeedDuplicates() throws {
        let container = try ClementineModelContainer.make(inMemory: true)
        let context = container.mainContext
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        context.insert(
            VocabularyNote(
                sourceID: "test-1",
                deckID: "test",
                hanzi: "爱",
                pinyin: "ài",
                english: "love",
                createdAt: older,
                updatedAt: older
            )
        )
        context.insert(
            VocabularyNote(
                sourceID: "test-1",
                deckID: "test",
                hanzi: "爱",
                pinyin: "ài",
                english: "to love",
                createdAt: newer,
                updatedAt: newer
            )
        )

        let unreviewedCard = StudyCard(noteSourceID: "test-1", kind: .hanziToMeaning, dueAt: older)
        unreviewedCard.updatedAt = older
        context.insert(unreviewedCard)

        let reviewedCard = StudyCard(noteSourceID: "test-1", kind: .hanziToMeaning, dueAt: newer)
        reviewedCard.updatedAt = newer
        reviewedCard.fsrsCardData = Data([1, 2, 3])
        context.insert(reviewedCard)

        try context.save()

        XCTAssertEqual(try SeedDeduplicator.removeDuplicateSeedRecords(context: context), 2)

        let notes = try context.fetch(FetchDescriptor<VocabularyNote>())
        let cards = try context.fetch(FetchDescriptor<StudyCard>())

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.english, "to love")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.cardKey, "test-1#hanziToMeaning")
        XCTAssertEqual(cards.first?.fsrsCardData, Data([1, 2, 3]))
    }

    func testDeduplicatorConsolidatesOldGeneratedCardsIntoOneVocabularyCard() throws {
        let container = try ClementineModelContainer.make(inMemory: true)
        let context = container.mainContext
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        context.insert(
            VocabularyNote(
                sourceID: "test-1",
                deckID: "test",
                hanzi: "爱",
                pinyin: "ài",
                english: "love",
                createdAt: older,
                updatedAt: older
            )
        )

        let meaningCard = StudyCard(noteSourceID: "test-1", kind: .hanziToMeaning, dueAt: older)
        meaningCard.updatedAt = older
        context.insert(meaningCard)

        let pinyinCard = StudyCard(noteSourceID: "test-1", kind: .hanziToPinyin, dueAt: newer)
        pinyinCard.updatedAt = newer
        pinyinCard.fsrsCardData = Data([9, 8, 7])
        context.insert(pinyinCard)

        context.insert(
            ReviewEvent(
                cardKey: "test-1#hanziToPinyin",
                noteSourceID: "test-1",
                grade: .good,
                interaction: .multipleChoice,
                wasCorrect: true,
                responseSeconds: 2
            )
        )

        try context.save()

        XCTAssertEqual(try SeedDeduplicator.removeDuplicateSeedRecords(context: context), 2)

        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let reviews = try context.fetch(FetchDescriptor<ReviewEvent>())

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.cardKey, "test-1#hanziToMeaning")
        XCTAssertEqual(cards.first?.kind, .hanziToMeaning)
        XCTAssertEqual(cards.first?.fsrsCardData, Data([9, 8, 7]))
        XCTAssertEqual(reviews.map(\.cardKey), ["test-1#hanziToMeaning"])
    }
}
