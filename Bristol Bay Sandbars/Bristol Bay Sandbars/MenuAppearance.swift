import SwiftUI
import UIKit

// Darker blue than systemBlue
public let menuBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
public let menuBlue = Color(uiColor: menuBlueUIColor)

enum MenuAppearance {

    /// Call once at app launch (most reliable for .sheet + iOS16)
    static func applyAll() {
        applyTabBar()
        applyNavBar()
    }

    static func applyTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = menuBlueUIColor

        // thin black line along top of tab bar
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.70)

        // Dark “pill” behind selected item (NOT white)
        let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
        appearance.selectionIndicatorImage = UIImage.selectionIndicator(
            fill: indicatorFill,
            stroke: UIColor.black.withAlphaComponent(0.70),
            lineWidth: 1,
            size: CGSize(width: 80, height: 30),
            cornerRadius: 12
        ).resizableImage(
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
        tabBar.isTranslucent = false
        tabBar.tintColor = .white
        tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.75)

        // “shorter” feel
        let item = UITabBarItem.appearance()
        item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -5)
        item.imageInsets = UIEdgeInsets(top: -3, left: 0, bottom: 3, right: 0)
    }

    static func applyNavBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = menuBlueUIColor
        nav.shadowColor = UIColor.black.withAlphaComponent(0.70) // thin black bottom line

        nav.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactAppearance = nav
        bar.tintColor = .white
    }
}

private extension UIImage {
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
