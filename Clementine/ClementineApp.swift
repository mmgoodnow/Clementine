import SwiftData
import SwiftUI

@main
struct ClementineApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ClementineModelContainer.make()
        } catch {
            fatalError("Could not create Clementine model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootBootstrapView()
        }
        .modelContainer(modelContainer)
        #if os(iOS)
        .backgroundTask(.appRefresh(AppBadgeUpdater.backgroundRefreshTaskIdentifier)) {
            await AppBadgeUpdater.refreshBadge(modelContainer: modelContainer)
            await MainActor.run {
                AppBadgeUpdater.scheduleBackgroundRefresh()
            }
        }
        #endif
    }
}

private struct RootBootstrapView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var seedError: Error?

    var body: some View {
        ContentView(seedError: seedError)
            .task {
                do {
                    let deck = try SeedDeckLoader.bundledHSK2Deck()
                    try SeedImporter.installIfNeeded(deck: deck, context: modelContext)
                } catch {
                    seedError = error
                }
                _ = await AppBadgeUpdater.requestBadgeAuthorization()
                await AppBadgeUpdater.refreshBadge(context: modelContext)
                AppBadgeUpdater.scheduleBackgroundRefresh()
            }
            .task {
                await AppBadgeUpdater.periodicRefresh(context: modelContext)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active || phase == .background else { return }
                Task {
                    await AppBadgeUpdater.refreshBadge(context: modelContext)
                    AppBadgeUpdater.scheduleBackgroundRefresh()
                }
            }
    }
}
