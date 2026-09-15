import SwiftUI
import FirebaseCore
import UIKit

final class SatChartAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == "com.curraghfisheries.SatChart.offline-mbtiles" else {
            completionHandler()
            return
        }
        OfflineMapsManager.shared.handleBackgroundURLSessionEvents(completionHandler: completionHandler)
    }
}

@main
struct SatChartApp: App {
    @UIApplicationDelegateAdaptor(SatChartAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keepDisplayOnWhileAppInUse") private var keepDisplayOnWhileAppInUse: Bool = true

    init() {
        FirebaseApp.configure()
        MenuAppearance.applyAll()

        Task {
            await TidesWeatherLaunchPrefetch.shared.prefetchIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            LaunchRouterView()
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .onAppear {
                    applyIdleTimerPreference(for: scenePhase, keepDisplayOn: keepDisplayOnWhileAppInUse)
                }
                .onChange(of: keepDisplayOnWhileAppInUse) { keepDisplayOn in
                    applyIdleTimerPreference(for: scenePhase, keepDisplayOn: keepDisplayOn)
                }
                .onChange(of: scenePhase) { phase in
                    applyIdleTimerPreference(for: phase, keepDisplayOn: keepDisplayOnWhileAppInUse)
                }
        }
    }

    private func applyIdleTimerPreference(for phase: ScenePhase, keepDisplayOn: Bool) {
        let shouldDisableIdleTimer = keepDisplayOn && phase == .active
        if UIApplication.shared.isIdleTimerDisabled != shouldDisableIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
        }
    }
}
