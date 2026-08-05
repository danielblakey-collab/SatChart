import SwiftUI

struct ContentView: View {
    @Environment(\.appDatabase) private var appDatabase
    @StateObject private var radioGroup = RadioGroupStore()

    var body: some View {
        NavigationView {
            Group {
                if appDatabase == nil {
                    VStack(spacing: 12) {
                        Text("Offline database not available")
                            .font(.headline)
                        Text("Please restart the app or reinstall offline data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    MapView()
                        .environmentObject(radioGroup)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // important for iPad behavior on iOS 15
    }
}
