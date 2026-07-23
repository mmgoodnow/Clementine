import Foundation
import SQLite3
import SwiftData

enum LegacySuspensionHistoryRepair {
    static func repair(context: ModelContext) throws -> Int {
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let stateEvents = try context.fetch(FetchDescriptor<CardStateEvent>())
        let sourcesWithSuspendEvents = Set(
            stateEvents
                .filter(\.isSuspended)
                .map(\.noteSourceID)
                .filter { !$0.isEmpty }
        )
        let cardsToRepair = cards.filter { card in
            card.isSuspended
                && card.suspendedAt == nil
                && !card.noteSourceID.isEmpty
                && !sourcesWithSuspendEvents.contains(card.noteSourceID)
        }

        guard !cardsToRepair.isEmpty else { return 0 }

        let inferredDates = inferSuspensionDatesFromPersistentHistory()
        guard !inferredDates.isEmpty else { return 0 }

        var repairedCount = 0
        for card in cardsToRepair {
            guard let suspendedAt = inferredDates[card.noteSourceID] else { continue }
            card.suspendedAt = suspendedAt
            context.insert(CardStateEvent(
                cardKey: card.cardKey,
                noteSourceID: card.noteSourceID,
                changedAt: suspendedAt,
                isSuspended: true
            ))
            repairedCount += 1
        }

        if repairedCount > 0 {
            try context.save()
        }

        return repairedCount
    }

    private static func inferSuspensionDatesFromPersistentHistory() -> [String: Date] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return [:]
        }
        defer { sqlite3_close(database) }

        let sql = """
        WITH last_review AS (
            SELECT c.Z_PK AS card_pk, c.ZNOTESOURCEID AS source, MAX(r.ZREVIEWEDAT) AS last_review
            FROM ZSTUDYCARD c
            LEFT JOIN ZREVIEWEVENT r ON r.ZNOTESOURCEID = c.ZNOTESOURCEID
            WHERE c.ZISSUSPENDED = 1
              AND c.ZSUSPENDEDAT IS NULL
              AND c.ZNOTESOURCEID != ''
              AND NOT EXISTS (
                  SELECT 1
                  FROM ZCARDSTATEEVENT e
                  WHERE e.ZNOTESOURCEID = c.ZNOTESOURCEID
                    AND e.ZISSUSPENDED = 1
              )
            GROUP BY c.Z_PK
        )
        SELECT lr.source, MIN(t.ZTIMESTAMP) AS inferred_suspended_at
        FROM last_review lr
        JOIN ACHANGE ch
          ON ch.ZENTITY = 4
         AND ch.ZENTITYPK = lr.card_pk
         AND ch.ZCHANGETYPE = 1
        JOIN ATRANSACTION t
          ON t.Z_PK = ch.ZTRANSACTIONID
        WHERE lr.last_review IS NULL
           OR t.ZTIMESTAMP >= lr.last_review
        GROUP BY lr.source
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var dates: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceCString = sqlite3_column_text(statement, 0) else { continue }
            let sourceID = String(cString: sourceCString)
            let timestamp = sqlite3_column_double(statement, 1)
            guard !sourceID.isEmpty, timestamp > 0 else { continue }
            dates[sourceID] = Date(timeIntervalSinceReferenceDate: timestamp)
        }

        return dates
    }

    private static var storeURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportURL.appendingPathComponent("Clementine.store")
    }
}
