import SwiftUI
import Combine

private struct AppDatabaseKey: EnvironmentKey {
    static var defaultValue: AppDatabase? = nil
}

extension EnvironmentValues {
    var appDatabase: AppDatabase? {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}

extension View {
    func appDatabase(_ db: AppDatabase) -> some View {
        environment(\.appDatabase, db)
    }
}
