import Foundation
import FSRS

enum FSRSReviewScheduler {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let scheduler = FSRS(
        parameters: FSRSParameters(w: FSRSDefaults.defaultWv6)
    )

    static func initialCardData(now: Date = Date()) throws -> Data {
        try encoder.encode(Card(due: now))
    }

    static func review(cardData: Data?, grade: ReviewGrade, now: Date = Date()) throws -> ScheduledReview {
        let card = try decodedCard(from: cardData, now: now)
        let result = try scheduler.next(card: card, now: now, grade: grade.fsrsRating)
        return ScheduledReview(
            cardData: try encoder.encode(result.card),
            dueAt: result.card.due,
            scheduledDays: result.card.scheduledDays,
            state: result.card.state.stringValue
        )
    }

    private static func decodedCard(from data: Data?, now: Date) throws -> Card {
        guard let data else { return Card(due: now) }
        return try decoder.decode(Card.self, from: data)
    }
}

struct ScheduledReview: Equatable {
    var cardData: Data
    var dueAt: Date
    var scheduledDays: Double
    var state: String
}

private extension ReviewGrade {
    var fsrsRating: Rating {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }
}
