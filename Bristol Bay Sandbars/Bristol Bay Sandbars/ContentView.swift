import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            MapView()
                .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle()) // important for iPad behavior on iOS 15
    }
}
