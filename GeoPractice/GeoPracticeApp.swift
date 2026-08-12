import SwiftData
import SwiftUI

@main
struct GeoPracticeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: PracticeEvent.self)
    }
}
