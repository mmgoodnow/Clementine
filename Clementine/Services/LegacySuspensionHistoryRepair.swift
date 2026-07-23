import Foundation
import SQLite3
import SwiftData

enum LegacySuspensionHistoryRepair {
    static func repair(context: ModelContext) throws -> Int {
        let cards = try context.fetch(FetchDescriptor<StudyCard>())
        let fetchedStateEvents = try context.fetch(FetchDescriptor<CardStateEvent>(
            sortBy: [SortDescriptor(\.changedAt)]
        ))
        let (stateEvents, removedDuplicateEventCount) = compactStateEvents(fetchedStateEvents, context: context)
        let suspendEventsBySourceID = Dictionary(
            grouping: stateEvents.filter { $0.isSuspended && !$0.noteSourceID.isEmpty },
            by: \.noteSourceID
        )
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

        let inferredDates = inferSuspensionDatesFromPersistentHistory()
        guard !inferredDates.isEmpty else { return 0 }

        var repairedCount = 0
        for (sourceID, card) in cardsBySourceID {
            guard let suspendedAt = inferredDates[sourceID] else { continue }

            let alreadyHasMatchingSuspendEvent = suspendEventsBySourceID[sourceID, default: []].contains { event in
                if let firstResume = firstResumeBySourceID[sourceID] {
                    return event.changedAt <= firstResume
                }
                return true
            }
            guard !alreadyHasMatchingSuspendEvent else { continue }

            if card.isSuspended {
                card.suspendedAt = suspendedAt
            }
            context.insert(CardStateEvent(
                cardKey: card.cardKey,
                noteSourceID: sourceID,
                changedAt: suspendedAt,
                isSuspended: true
            ))
            repairedCount += 1
        }

        if repairedCount > 0 || removedDuplicateEventCount > 0 {
            try context.save()
        }

        return repairedCount + removedDuplicateEventCount
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

    private static func inferSuspensionDatesFromPersistentHistory() -> [String: Date] {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return [:]
        }
        defer { sqlite3_close(database) }

        let sql = """
        WITH first_resume AS (
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
                fr.resume_at AS upper_bound,
                MAX(r.ZREVIEWEDAT) AS last_review
            FROM ZSTUDYCARD c
            LEFT JOIN first_resume fr
              ON fr.source = c.ZNOTESOURCEID
            LEFT JOIN ZREVIEWEVENT r ON r.ZNOTESOURCEID = c.ZNOTESOURCEID
                AND (fr.resume_at IS NULL OR r.ZREVIEWEDAT <= fr.resume_at)
            WHERE (
                    c.ZISSUSPENDED = 1
                    OR fr.resume_at IS NOT NULL
                )
              AND c.ZNOTESOURCEID != ''
              AND NOT EXISTS (
                  SELECT 1
                  FROM ZCARDSTATEEVENT e
                  WHERE e.ZNOTESOURCEID = c.ZNOTESOURCEID
                    AND e.ZISSUSPENDED = 1
                    AND (fr.resume_at IS NULL OR e.ZCHANGEDAT <= fr.resume_at)
              )
            GROUP BY c.Z_PK
        )
        SELECT cc.source, MIN(t.ZTIMESTAMP) AS inferred_suspended_at
        FROM candidate_cards cc
        JOIN ACHANGE ch
          ON ch.ZENTITY = 4
         AND ch.ZENTITYPK = cc.card_pk
         AND ch.ZCHANGETYPE = 1
        JOIN ATRANSACTION t
          ON t.Z_PK = ch.ZTRANSACTIONID
        WHERE (cc.last_review IS NULL OR t.ZTIMESTAMP >= cc.last_review)
          AND (cc.upper_bound IS NULL OR t.ZTIMESTAMP <= cc.upper_bound)
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
