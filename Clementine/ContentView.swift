import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .study

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                StudyPlaceholderView()
            }
            .tabItem { Label("Study", systemImage: "character.book.closed") }
            .tag(AppTab.study)

            NavigationStack {
                ProgressPlaceholderView()
            }
            .tabItem { Label("Progress", systemImage: "chart.bar") }
            .tag(AppTab.progress)

            NavigationStack {
                SettingsPlaceholderView()
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            .tag(AppTab.settings)
        }
    }
}

private enum AppTab: Hashable {
    case study
    case progress
    case settings
}

private struct StudyPlaceholderView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Text("柑")
                    .font(.system(size: 108, weight: .semibold, design: .serif))
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel("Sample hanzi")

                Text("Open Clementine when you can. It will choose the next card.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("study.start")

            Spacer(minLength: 24)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClementineTheme.background)
        .navigationTitle("Clementine")
    }
}

private struct ProgressPlaceholderView: View {
    var body: some View {
        List {
            LabeledContent("Deck", value: "HSK2 seed")
            LabeledContent("Sync", value: "iCloud")
            LabeledContent("Scheduler", value: "FSRS")
        }
        .navigationTitle("Progress")
    }
}

private struct SettingsPlaceholderView: View {
    @State private var pace: LearningPace = .balanced

    var body: some View {
        Form {
            Picker("Learning Pace", selection: $pace) {
                ForEach(LearningPace.allCases) { pace in
                    Text(pace.title).tag(pace)
                }
            }
            .pickerStyle(.segmented)
        }
        .navigationTitle("Settings")
    }
}

private enum ClementineTheme {
    static var background: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.97, blue: 0.94),
                Color(red: 0.93, green: 0.96, blue: 0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    ContentView()
}
