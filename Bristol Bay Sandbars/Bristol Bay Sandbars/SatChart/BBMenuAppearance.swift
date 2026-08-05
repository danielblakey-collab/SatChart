import SwiftUI
import UIKit

/// Darker blue than `systemBlue` for consistent Menu + Waypoints nav/tab bars.
/// NOTE: keep these NON-private so other files can use them.
let bbMenuBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
let bbMenuBlue = Color(uiColor: bbMenuBlueUIColor)

enum BBMenuAppearance {

    static func applyNavBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bbMenuBlueUIColor
        nav.shadowColor = UIColor.black.withAlphaComponent(0.70)

        let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
        nav.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: titleFont
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactAppearance = nav
        bar.tintColor = .white
    }
 /// IMPORTANT: call this BEFORE the TabView is created (i.e., before presenting the sheet)
    static func applyTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bbMenuBlueUIColor
        // Use a consistent thin black separator (avoids the “blue strike” artifact)
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.70)
        appearance.shadowImage = nil

        let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
        let indicator = UIImage.selectionIndicator(
            fill: indicatorFill,
            stroke: UIColor.black.withAlphaComponent(0.88),
            lineWidth: 1.5,
            size: CGSize(width: 82, height: 34),
            cornerRadius: 12
        )

        appearance.selectionIndicatorImage = indicator.resizableImage(
            withCapInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
            resizingMode: .stretch
        )

        let font = UIFont.systemFont(ofSize: 8, weight: .semibold)
        let layouts: [UITabBarItemAppearance] = [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ]

        for item in layouts {
            item.normal.iconColor = UIColor.white.withAlphaComponent(0.75)
            item.normal.titleTextAttributes = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                .font: font
            ]

            item.selected.iconColor = UIColor.white
            item.selected.titleTextAttributes = [
                .foregroundColor: UIColor.white,
                .font: font
            ]
        }

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
        // Hard kill any remaining top separator/shadow artifacts
        tabBar.layer.masksToBounds = true
        tabBar.layer.shadowOpacity = 0
        tabBar.layer.shadowRadius = 0
        tabBar.layer.shadowOffset = .zero
        tabBar.layer.shadowColor = nil
        if #available(iOS 13.0, *) {
            tabBar.layer.borderWidth = 0
            tabBar.layer.borderColor = nil
        }

        tabBar.isTranslucent = false
        tabBar.tintColor = UIColor.white
        tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.75)

        // Extra force for stubborn cases (especially TabView inside a sheet)
        tabBar.backgroundColor = bbMenuBlueUIColor
        tabBar.barTintColor = bbMenuBlueUIColor
        tabBar.layer.backgroundColor = bbMenuBlueUIColor.cgColor

        // “Raised” feel: push icons/titles up a bit more
        let item = UITabBarItem.appearance()
        item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -8)
        item.imageInsets = UIEdgeInsets(top: -5, left: 0, bottom: 5, right: 0)
    }

    static func applyAll() {
        applyNavBar()
        applyTabBar()
    }
}

// Ensures the TabView tab bar shows our dark-blue background when presented in a sheet (iOS 16+).
struct TabBarBlueBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

// Forces the *actual* UITabBarController created by SwiftUI TabView to adopt our appearance.
struct TabBarControllerConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { ConfigVC() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class ConfigVC: UIViewController {
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); applyWithRetry() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); applyWithRetry() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); applyOnce() }

        private func applyWithRetry() {
            applyOnce()
            DispatchQueue.main.async { [weak self] in self?.applyOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in self?.applyOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.applyOnce() }
        }

        private func findTabBarController() -> UITabBarController? {
            if let tbc = self.tabBarController { return tbc }
            var p: UIViewController? = self.parent
            while let cur = p {
                if let tbc = cur as? UITabBarController { return tbc }
                if let tbc = cur.tabBarController { return tbc }
                p = cur.parent
            }
            return nil
        }

        private func applyOnce() {
            guard let tbc = findTabBarController() else { return }

            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = bbMenuBlueUIColor
            // Use a consistent thin black separator (avoids the “blue strike” artifact)
            appearance.shadowColor = UIColor.black.withAlphaComponent(0.70)
            appearance.shadowImage = nil

            let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
            let indicator = UIImage.selectionIndicator(
                fill: indicatorFill,
                stroke: UIColor.black.withAlphaComponent(0.88),
                lineWidth: 1.5,
                size: CGSize(width: 82, height: 34),
                cornerRadius: 12
            )
            appearance.selectionIndicatorImage = indicator.resizableImage(
                withCapInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
                resizingMode: .stretch
            )

            let font = UIFont.systemFont(ofSize: 8, weight: .semibold)
            let layouts: [UITabBarItemAppearance] = [
                appearance.stackedLayoutAppearance,
                appearance.inlineLayoutAppearance,
                appearance.compactInlineLayoutAppearance
            ]
            for item in layouts {
                item.normal.iconColor = UIColor.white.withAlphaComponent(0.75)
                item.normal.titleTextAttributes = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                    .font: font
                ]
                item.selected.iconColor = UIColor.white
                item.selected.titleTextAttributes = [
                    .foregroundColor: UIColor.white,
                    .font: font
                ]
            }

            let tabBar = tbc.tabBar
            tabBar.isTranslucent = false
            tabBar.standardAppearance = appearance
            if #available(iOS 15.0, *) {
                tabBar.scrollEdgeAppearance = appearance
            }
            // Hard kill any remaining top separator/shadow artifacts
            tabBar.layer.masksToBounds = true
            tabBar.layer.shadowOpacity = 0
            tabBar.layer.shadowRadius = 0
            tabBar.layer.shadowOffset = .zero
            tabBar.layer.shadowColor = nil
            if #available(iOS 13.0, *) {
                tabBar.layer.borderWidth = 0
                tabBar.layer.borderColor = nil
            }

            tabBar.backgroundColor = bbMenuBlueUIColor
            tabBar.barTintColor = bbMenuBlueUIColor
            tabBar.layer.backgroundColor = bbMenuBlueUIColor.cgColor

            tabBar.tintColor = .white
            tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.75)

            for item in tabBar.items ?? [] {
                item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -8)
                item.imageInsets = UIEdgeInsets(top: -5, left: 0, bottom: 5, right: 0)
            }
        }
    }
}

extension UIImage {
    static func selectionIndicator(
        fill: UIColor,
        stroke: UIColor,
        lineWidth: CGFloat,
        size: CGSize,
        cornerRadius: CGFloat
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

            fill.setFill()
            path.fill()

            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }
}
