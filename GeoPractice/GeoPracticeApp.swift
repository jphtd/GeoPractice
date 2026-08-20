import CoreText
import Foundation
import SwiftData
import SwiftUI

@main
struct GeoPracticeApp: App {
    init() {
        BundledFontRegistry.registerBravuraText()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [
            PracticeEvent.self,
            PracticeAttempt.self,
            PracticeFolder.self,
            PracticeDailyGoal.self
        ])
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
