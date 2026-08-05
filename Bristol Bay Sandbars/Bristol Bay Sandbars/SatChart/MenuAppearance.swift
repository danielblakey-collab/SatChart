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
        let tabBar = UITabBar.appearance()
        let item = UITabBarItem.appearance()

        // Keep icon colors
        tabBar.tintColor = .white
        tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.75)

        // “shorter” feel
        item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -5)
        item.imageInsets = UIEdgeInsets(top: -3, left: 0, bottom: 3, right: 0)

        let font = UIFont.systemFont(ofSize: 8, weight: .semibold)

        if #available(iOS 26.0, *) {
            // On iOS 26, do NOT force the old opaque tab bar model.
            // Let SwiftUI's `.toolbarBackground(..., for: .tabBar)` drive the visual styling.
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
            appearance.selectionIndicatorImage = nil
            appearance.backgroundEffect = nil

            let layouts: [UITabBarItemAppearance] = [
                appearance.stackedLayoutAppearance,
                appearance.inlineLayoutAppearance,
                appearance.compactInlineLayoutAppearance
            ]

            for itemAppearance in layouts {
                itemAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.75)
                itemAppearance.normal.titleTextAttributes = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                    .font: font
                ]
                itemAppearance.selected.iconColor = UIColor.white
                itemAppearance.selected.titleTextAttributes = [
                    .foregroundColor: UIColor.white,
                    .font: font
                ]
            }

            tabBar.isTranslucent = true
            tabBar.backgroundColor = nil
            tabBar.barTintColor = nil
            tabBar.layer.backgroundColor = nil
            tabBar.layer.borderWidth = 0
            tabBar.layer.borderColor = UIColor.clear.cgColor
            tabBar.layer.shadowOpacity = 0
            tabBar.shadowImage = UIImage()
            tabBar.backgroundImage = UIImage()
            tabBar.clipsToBounds = false
            return
        }

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = menuBlueUIColor
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        appearance.backgroundEffect = nil

        let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
        let indicator = UIImage.bbSelectionIndicator(
            fill: indicatorFill,
            stroke: UIColor.white.withAlphaComponent(0.14),
            lineWidth: 1,
            size: CGSize(width: 80, height: 30),
            cornerRadius: 12
        )

        appearance.selectionIndicatorImage = indicator.resizableImage(
            withCapInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
            resizingMode: .stretch
        )

        let layouts: [UITabBarItemAppearance] = [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ]

        for itemAppearance in layouts {
            itemAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.75)
            itemAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                .font: font
            ]
            itemAppearance.selected.iconColor = UIColor.white
            itemAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor.white,
                .font: font
            ]
        }

        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }

        tabBar.isTranslucent = false
        tabBar.backgroundColor = menuBlueUIColor
        tabBar.barTintColor = menuBlueUIColor
        tabBar.layer.backgroundColor = menuBlueUIColor.cgColor
        tabBar.layer.borderWidth = 0
        tabBar.layer.borderColor = UIColor.clear.cgColor
        tabBar.layer.shadowOpacity = 0
        tabBar.shadowImage = UIImage()
        tabBar.backgroundImage = UIImage()
        tabBar.clipsToBounds = true
    }

    static func applyNavBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = menuBlueUIColor
        nav.shadowColor = .clear

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
    static func bbSelectionIndicator(
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
