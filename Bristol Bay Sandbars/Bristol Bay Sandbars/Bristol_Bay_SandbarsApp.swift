import SwiftUI

@main
struct Bristol_Bay_SandbarsApp: App {

    init() {
        MenuAppearance.applyAll()
    }

    var body: some Scene {
        WindowGroup {
            MapView()
        }
    }
}
