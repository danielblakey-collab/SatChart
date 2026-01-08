import SwiftUI
import FirebaseCore

@main
struct SatChartApp: App {

    init() {
        FirebaseApp.configure()
        MenuAppearance.applyAll()
    }

    var body: some Scene {
        WindowGroup {
            MapView()
        }
    }
}
