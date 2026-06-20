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
        XCTAssertEqual(Set(cards.map(\.cardKey)), [
            "test-1#hanziToMeaning",
            "test-1#hanziToPinyin",
            "test-1#recall"
        ])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(installs.map(\.deckID), ["test"])
    }

    func testSeedImportOrdersNewCardsByDeckOrderAndSeparatesVariations() throws {
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

        XCTAssertEqual(cards.prefix(3).map(\.noteSourceID), ["test-1", "test-2", "test-3"])
        XCTAssertEqual(Set(cards.prefix(3).map(\.kind)), [.hanziToMeaning])
        XCTAssertEqual(cards.dropFirst(3).prefix(3).map(\.noteSourceID), ["test-1", "test-2", "test-3"])
        XCTAssertEqual(Set(cards.dropFirst(3).prefix(3).map(\.kind)), [.hanziToPinyin])
        XCTAssertEqual(cards.dropFirst(6).prefix(3).map(\.noteSourceID), ["test-1", "test-2", "test-3"])
        XCTAssertEqual(Set(cards.dropFirst(6).prefix(3).map(\.kind)), [.recall])
    }
}
