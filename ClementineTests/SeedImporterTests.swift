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
}
