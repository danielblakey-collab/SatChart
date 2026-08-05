import Foundation
import SwiftUI
import UIKit
import FirebaseFirestore

enum WaypointPinColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case red
    case orange
    case amber
    case yellow
    case brown
    case blue
    case skyBlue
    case navy
    case indigo
    case purple
    case violet
    case magenta
    case pink
    case coral
    case cyan
    case teal

    var id: String { rawValue }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        switch self {
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .amber:
            return UIColor(red: 0.95, green: 0.60, blue: 0.08, alpha: 1.0)
        case .yellow:
            return .systemYellow
        case .brown:
            return .systemBrown
        case .blue:
            return .systemBlue
        case .skyBlue:
            return UIColor(red: 0.28, green: 0.70, blue: 1.0, alpha: 1.0)
        case .navy:
            return UIColor(red: 0.02, green: 0.17, blue: 0.52, alpha: 1.0)
        case .indigo:
            return .systemIndigo
        case .purple:
            return .systemPurple
        case .violet:
            return UIColor(red: 0.52, green: 0.25, blue: 0.95, alpha: 1.0)
        case .magenta:
            return .systemPink
        case .pink:
            return UIColor(red: 1.0, green: 0.45, blue: 0.70, alpha: 1.0)
        case .coral:
            return UIColor(red: 1.0, green: 0.42, blue: 0.34, alpha: 1.0)
        case .cyan:
            return .systemCyan
        case .teal:
            return .systemTeal
        }
    }

    var label: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .amber: return "Amber"
        case .yellow: return "Yellow"
        case .brown: return "Brown"
        case .blue: return "Blue"
        case .skyBlue: return "Sky Blue"
        case .navy: return "Navy"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .violet: return "Violet"
        case .magenta: return "Magenta"
        case .pink: return "Pink"
        case .coral: return "Coral"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        }
    }

    static var selectableCases: [WaypointPinColor] {
        allCases
    }

    static func random<R: RandomNumberGenerator>(using rng: inout R) -> WaypointPinColor {
        selectableCases.randomElement(using: &rng) ?? .red
    }

    static func firstAvailable(excluding used: Set<WaypointPinColor>) -> WaypointPinColor? {
        selectableCases.first { !used.contains($0) }
    }

    static func safe(rawValue: String?, fallback: WaypointPinColor = .red) -> WaypointPinColor {
        guard let rawValue,
              let color = WaypointPinColor(rawValue: rawValue),
              selectableCases.contains(color)
        else {
            return fallback
        }
        return color
    }

    static func deterministicFallback(seed: String) -> WaypointPinColor {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .red }

        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        let palette = selectableCases
        return palette[Int(hash % UInt64(palette.count))]
    }
}

enum WaypointColorPreferences {
    static let storageKey = "defaultWaypointPinColorID"

    static func storedColor(defaults: UserDefaults = .standard) -> WaypointPinColor? {
        let raw = defaults.string(forKey: storageKey)
        guard let raw, let color = WaypointPinColor(rawValue: raw) else { return nil }
        return color
    }

    @discardableResult
    static func ensureLocalDefaultColor(defaults: UserDefaults = .standard) -> WaypointPinColor {
        if let stored = storedColor(defaults: defaults) {
            return stored
        }

        var generator = SystemRandomNumberGenerator()
        let color = WaypointPinColor.random(using: &generator)
        defaults.set(color.rawValue, forKey: storageKey)
        return color
    }

    static func mirrorToLocal(_ color: WaypointPinColor, defaults: UserDefaults = .standard) {
        defaults.set(color.rawValue, forKey: storageKey)
    }

    static func userDefaultColor(from data: [String: Any]) -> WaypointPinColor? {
        let raw = (data["defaultWaypointPinColorID"] as? String)
            ?? (data["waypointPinColorID"] as? String)
            ?? (data["colorID"] as? String)
        guard let raw else { return nil }
        return WaypointPinColor(rawValue: raw)
    }

    @discardableResult
    static func ensureDefaultColorFields(in updates: inout [String: Any], existingData: [String: Any]) -> WaypointPinColor {
        if let existing = userDefaultColor(from: existingData) {
            mirrorToLocal(existing)
            return existing
        }

        let color = ensureLocalDefaultColor()
        updates["defaultWaypointPinColorID"] = color.rawValue
        return color
    }

    static func ensureCloudDefaultColor(uid: String, db: Firestore = Firestore.firestore()) async throws -> WaypointPinColor {
        let ref = db.collection("users").document(uid)
        let snapshot = try await getDocument(ref)
        let data = snapshot.data() ?? [:]

        if let existing = userDefaultColor(from: data) {
            mirrorToLocal(existing)
            return existing
        }

        let color = ensureLocalDefaultColor()
        try await setData([
            "defaultWaypointPinColorID": color.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ], on: ref, merge: true)
        return color
    }

    static func updateCloudDefaultColor(uid: String, colorID: String, db: Firestore = Firestore.firestore()) async throws {
        let color = WaypointPinColor.safe(rawValue: colorID)
        mirrorToLocal(color)
        try await setData([
            "defaultWaypointPinColorID": color.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ], on: db.collection("users").document(uid), merge: true)
    }

    private static func getDocument(_ ref: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            ref.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: NSError(domain: "WaypointColorPreferences", code: 1))
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private static func setData(_ data: [String: Any], on ref: DocumentReference, merge: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ref.setData(data, merge: merge) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }
}
