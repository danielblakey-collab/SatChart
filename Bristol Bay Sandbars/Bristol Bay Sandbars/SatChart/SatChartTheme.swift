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

// MARK: - Stable member colors (Radio Group / Waypoints)

// Deterministic FNV-1a 64-bit hash (stable across launches)
private func fnv1a64(_ s: String) -> UInt64 {
    var hash: UInt64 = 14695981039346656037
    let prime: UInt64 = 1099511628211
    for b in s.utf8 {
        hash ^= UInt64(b)
        hash &*= prime
    }
    return hash
}

// IMPORTANT:
// - Red is RESERVED for "you" (local user).
// - These palettes must NEVER include red or pink.

private let scMemberPaletteSwiftUI: [Color] = [
    .green, .orange, .yellow, .purple, .cyan, .mint, .indigo
]

private let scMemberPaletteUIKit: [UIColor] = [
    .systemGreen, .systemOrange, .systemYellow,
    .systemPurple, .systemCyan, .systemMint, .systemIndigo
]

/// Stable SwiftUI color for a Radio Group member (by senderUid).
/// Same uid will ALWAYS map to the same color.
func scMemberColor(for senderUid: String) -> Color {
    let uid = senderUid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uid.isEmpty else { return .gray }
    let idx = Int(fnv1a64(uid) % UInt64(scMemberPaletteSwiftUI.count))
    return scMemberPaletteSwiftUI[idx]
}

/// Stable UIKit color for map annotations (by senderUid).
func scMemberUIColor(for senderUid: String) -> UIColor {
    let uid = senderUid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !uid.isEmpty else { return .systemGray }
    let idx = Int(fnv1a64(uid) % UInt64(scMemberPaletteUIKit.count))
    return scMemberPaletteUIKit[idx]
}
