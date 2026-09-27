import CoreText
import Foundation
import SwiftData
import SwiftUI
import UIKit

@main
struct GeoPracticeApp: App {
    private let persistentContainer: ModelContainer?
    private let persistenceFailureMessage: String?
    private var coreFixture: CoreFixture? = nil
    @StateObject private var subscriptionStore = SubscriptionStore()

    init() {
        BundledFontRegistry.registerBravuraText()
        GeoAppearance.configureNavigationBars()

        do {
#if DEBUG
            if let name = CoreFixture.requested {
                let container = try ModelContainer(for: PracticeSong.self, PracticeEvent.self, PracticeAttempt.self, PracticeFolder.self, PracticeDailyGoal.self,
                    // In-memory fixtures must also opt out of automatic CloudKit.
                    // Signed Xcode runs carry the app's iCloud entitlements.
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                coreFixture = try CoreFixture.make(name, context: container.mainContext)
                persistentContainer = container
            } else {
                coreFixture = nil
                persistentContainer = try GeoPracticePersistence.makeContainer()
            }
#else
            coreFixture = nil
            persistentContainer = try GeoPracticePersistence.makeContainer()
#endif
            persistenceFailureMessage = nil
        } catch {
            // Never silently fall back to an empty in-memory store. That makes
            // durable data look deleted and lets new edits disappear on the
            // next launch. A blocking read-only failure screen is safer.
            persistentContainer = nil
            persistenceFailureMessage = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let persistentContainer {
                    PracticeCoreRootView(fixture: coreFixture)
                        .modelContainer(persistentContainer)
                } else {
                    PersistenceUnavailableView(
                        diagnostic: persistenceFailureMessage ?? "未知错误"
                    )
                }
            }
            .environmentObject(subscriptionStore)
            .task {
                await subscriptionStore.prepare()
            }
        }
    }
}

enum GeoPracticePersistence {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            PracticeSong.self,
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [localConfiguration(schema: schema)]
        )
    }

    static func localConfiguration(
        schema: Schema,
        url: URL? = nil
    ) -> ModelConfiguration {
        // iCloud is implemented by `ICloudSyncService` as a versioned,
        // conflict-aware document sync. The SwiftData store itself must remain
        // local: leaving this as `.automatic` makes the presence of iCloud
        // entitlements opt SwiftData into CloudKit, whose schema restrictions
        // reject this existing local model (unique IDs and required fields).
        if let url {
            return ModelConfiguration(
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        }
        return ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
    }
}

private struct PersistenceUnavailableView: View {
    let diagnostic: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44, weight: .semibold))
            Text("暂时无法读取练习资料")
                .font(.title3.weight(.bold))
            Text("本机数据没有被清除。请关闭并重新打开应用；若仍无法读取，请保留应用并联系开发者处理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(diagnostic)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private enum GeoAppearance {
    static func configureNavigationBars() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .light ? .white : .black
        }
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
    }
}

private enum BundledFontRegistry {
    private static let didRegisterBravuraText: Bool = {
        guard let fontURL = Bundle.main.url(
            forResource: "BravuraText",
            withExtension: "otf"
        ) else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    static func registerBravuraText() {
        _ = didRegisterBravuraText
    }
}
