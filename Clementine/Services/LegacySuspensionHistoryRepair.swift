import Foundation
import SQLite3
import SwiftData

enum LegacySuspensionHistoryRepair {
    private static let suspensionFeatureReferenceTimestamp: TimeInterval = 804_880_800
    private static let minimumBulkTransactionSourceCount = 20

    static func repair(context: ModelContext) throws -> Int {
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let fetchedStateEvents = try context.fetch(FetchDescriptor<CardStateEvent>(
            sortBy: [SortDescriptor(\.changedAt)]
        ))
        let (stateEvents, removedDuplicateEventCount) = compactStateEvents(fetchedStateEvents, context: context)
        let firstResumeBySourceID = Dictionary(
            grouping: stateEvents.filter { !$0.isSuspended && !$0.noteSourceID.isEmpty },
            by: \.noteSourceID
        ).compactMapValues { events in
            events.map(\.changedAt).min()
        }
        let cardsBySourceID = Dictionary(
            cards.filter { !$0.noteSourceID.isEmpty }.map { ($0.noteSourceID, $0) },
            uniquingKeysWith: { lhs, rhs in
                if lhs.isSuspended != rhs.isSuspended {
                    return lhs.isSuspended ? lhs : rhs
                }
                return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
            }
        )

        let inferredDates = inferSuspensionDatesFromBulkPersistentHistory()
        let suspensionFeatureReferenceDate = Date(
            timeIntervalSinceReferenceDate: suspensionFeatureReferenceTimestamp
        )

        var repairedCount = 0
        var eventsToInsert: [CardStateEvent] = []
        var eventIDsToDelete = Set<UUID>()
        let suspendEventsBySourceID = Dictionary(
            grouping: stateEvents.filter { $0.isSuspended && !$0.noteSourceID.isEmpty },
            by: \.noteSourceID
        )

        for events in suspendEventsBySourceID.values {
            for event in events where event.changedAt < suspensionFeatureReferenceDate {
                eventIDsToDelete.insert(event.id)
            }
        }

        for (sourceID, card) in cardsBySourceID {
            guard let suspendedAt = inferredDates[sourceID] else { continue }

            let firstResume = firstResumeBySourceID[sourceID]
            let firstSegmentSuspendEvents = suspendEventsBySourceID[sourceID, default: []].filter { event in
                guard let firstResume else { return true }
                return event.changedAt <= firstResume
            }
            let hasCorrectedEvent = firstSegmentSuspendEvents.contains { event in
                abs(event.changedAt.timeIntervalSince(suspendedAt)) < 1
            }
            guard !hasCorrectedEvent else { continue }

            for event in firstSegmentSuspendEvents {
                eventIDsToDelete.insert(event.id)
            }
            if card.isSuspended, firstResume == nil {
                card.suspendedAt = suspendedAt
            }
            eventsToInsert.append(CardStateEvent(
                cardKey: card.cardKey,
                noteSourceID: sourceID,
                changedAt: suspendedAt,
                isSuspended: true
            ))
            repairedCount += 1
        }

        for event in stateEvents where eventIDsToDelete.contains(event.id) {
            context.delete(event)
        }
        for event in eventsToInsert {
            context.insert(event)
        }

        if repairedCount > 0 || removedDuplicateEventCount > 0 || !eventIDsToDelete.isEmpty {
            try context.save()
        }

        return repairedCount + removedDuplicateEventCount + eventIDsToDelete.count
    }

    private static func compactStateEvents(
        _ events: [CardStateEvent],
        context: ModelContext
    ) -> (kept: [CardStateEvent], removedCount: Int) {
        let groupedEvents = Dictionary(grouping: events) { event in
            if !event.noteSourceID.isEmpty {
                return "source:\(event.noteSourceID)"
            }
            return "card:\(event.cardKey)"
        }

        var keptEvents: [CardStateEvent] = []
        var removedCount = 0

        for timeline in groupedEvents.values {
            var lastKeptState: Bool?
            for event in timeline.sorted(by: { lhs, rhs in
                if lhs.changedAt != rhs.changedAt { return lhs.changedAt < rhs.changedAt }
                if lhs.isSuspended != rhs.isSuspended { return lhs.isSuspended && !rhs.isSuspended }
                return lhs.id.uuidString < rhs.id.uuidString
            }) {
                if lastKeptState == event.isSuspended {
                    context.delete(event)
                    removedCount += 1
                } else {
                    keptEvents.append(event)
                    lastKeptState = event.isSuspended
                }
            }
        }

        return (keptEvents, removedCount)
    }

    private static func inferSuspensionDatesFromBulkPersistentHistory() -> [String: Date] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return [:]
        }
        defer { sqlite3_close(database) }

        let sql = """
        WITH source_updates AS (
            SELECT
                t.Z_PK AS transaction_id,
                t.ZTIMESTAMP AS timestamp,
                c.ZNOTESOURCEID AS source
            FROM ATRANSACTION t
            JOIN ACHANGE ch
              ON ch.ZTRANSACTIONID = t.Z_PK
             AND ch.ZENTITY = 4
             AND ch.ZCHANGETYPE = 1
            JOIN ZSTUDYCARD c
              ON c.Z_PK = ch.ZENTITYPK
            WHERE t.ZTIMESTAMP >= \(suspensionFeatureReferenceTimestamp)
              AND c.ZNOTESOURCEID != ''
        ),
        bulk_transactions AS (
            SELECT transaction_id, timestamp
            FROM source_updates
            GROUP BY transaction_id
            HAVING COUNT(DISTINCT source) >= \(minimumBulkTransactionSourceCount)
        ),
        first_resume AS (
            SELECT ZNOTESOURCEID AS source, MIN(ZCHANGEDAT) AS resume_at
            FROM ZCARDSTATEEVENT
            WHERE ZISSUSPENDED = 0
              AND ZNOTESOURCEID != ''
            GROUP BY ZNOTESOURCEID
        ),
        candidate_cards AS (
            SELECT
                c.Z_PK AS card_pk,
                c.ZNOTESOURCEID AS source,
                fr.resume_at AS upper_bound
            FROM ZSTUDYCARD c
            LEFT JOIN first_resume fr
              ON fr.source = c.ZNOTESOURCEID
            WHERE (
                    c.ZISSUSPENDED = 1
                    OR fr.resume_at IS NOT NULL
                )
              AND c.ZNOTESOURCEID != ''
            GROUP BY c.Z_PK
        )
        SELECT cc.source, MIN(su.timestamp) AS inferred_suspended_at
        FROM candidate_cards cc
        JOIN source_updates su
          ON su.source = cc.source
        JOIN bulk_transactions bt
          ON bt.transaction_id = su.transaction_id
        WHERE (cc.upper_bound IS NULL OR su.timestamp <= cc.upper_bound)
        GROUP BY cc.source
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
