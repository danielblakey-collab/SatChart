import SwiftUI
import UIKit

// MARK: - SatChart Theme Colors (SwiftUI)

let scBackground = Color(red: 0.10, green: 0.11, blue: 0.13)   // softer dark-neutral
let scSurface    = Color(red: 0.16, green: 0.18, blue: 0.22)   // primary card surface
let scSurfaceAlt = Color(red: 0.20, green: 0.23, blue: 0.28)   // grouped / secondary surface

let scTextPrimary   = Color(red: 0.95, green: 0.96, blue: 0.98)
let scTextSecondary = Color(red: 0.74, green: 0.78, blue: 0.83)

// Accent color (primary interactive color)
let scAccent = Color(red: 0.22, green: 0.55, blue: 0.90)       // SatChart blue

// MARK: - UIKit equivalents (for background fixing)

let scBackgroundUIColor = UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
let scSurfaceUIColor    = UIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0)
let scSurfaceAltUIColor = UIColor(red: 0.20, green: 0.23, blue: 0.28, alpha: 1.0)

// MARK: - Hosting background fixer
// Use this in any List / NavigationStack page to eliminate white safe zones.

struct HostingBackgroundFixer: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIView {
        FixView(color: color)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? FixView)?.color = color
        (uiView as? FixView)?.apply()
    }

    private final class FixView: UIView {
        var color: UIColor

        init(color: UIColor) {
            self.color = color
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.superview?.backgroundColor = self.color
                self.superview?.superview?.backgroundColor = self.color
                self.superview?.superview?.superview?.backgroundColor = self.color
            }
        }
    }
}
