import SwiftData
import Security

enum ClementineModelContainer {
    static let iCloudContainerIdentifier = "iCloud.com.mmgoodnow.Clementine"

    static var schema: Schema {
        Schema([
            VocabularyNote.self,
            StudyCard.self,
            ReviewEvent.self,
            UserSettings.self,
            SeedInstall.self
        ])
    }

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = {
            guard !inMemory, hasCloudKitEntitlement else { return .none }
            return .private(iCloudContainerIdentifier)
        }()

        let configuration = ModelConfiguration(
            "Clementine",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKitDatabase
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) as? [String] else {
            return false
        }

        return value.contains("CloudKit")
    }
}
