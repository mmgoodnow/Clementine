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
    }
}

private struct RootBootstrapView: View {
    @Environment(\.modelContext) private var modelContext
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
            }
    }
}
