import Foundation
import SwiftData
import UserNotifications

#if os(iOS)
import BackgroundTasks
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum AppBadgeUpdater {
    static let backgroundRefreshTaskIdentifier = "com.mmgoodnow.Clementine.badge-refresh"
    private static let refreshInterval: TimeInterval = 15 * 60

    static func requestBadgeAuthorization() async -> Bool {
        #if os(iOS)
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    static func refreshBadge(context: ModelContext, now: Date = Date()) async {
        let count = dueReviewCount(context: context, now: now)
        await setBadgeCount(count)
    }

    static func refreshBadge(modelContainer: ModelContainer, now: Date = Date()) async {
        await refreshBadge(context: modelContainer.mainContext, now: now)
    }

    static func periodicRefresh(context: ModelContext) async {
        while !Task.isCancelled {
            await refreshBadge(context: context)
            try? await Task.sleep(for: .seconds(refreshInterval))
        }
    }

    static func scheduleBackgroundRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    static func dueReviewCount(context: ModelContext, now: Date = Date()) -> Int {
        let descriptor = FetchDescriptor<StudyCard>()
        let cards = (try? context.fetch(descriptor)) ?? []
        return cards.filter { card in
            !card.isSuspended &&
                card.fsrsCardData != nil &&
                card.dueAt <= now
        }.count
    }

    private static func setBadgeCount(_ count: Int) async {
        #if os(iOS)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        #elseif os(macOS)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #endif
    }
}
