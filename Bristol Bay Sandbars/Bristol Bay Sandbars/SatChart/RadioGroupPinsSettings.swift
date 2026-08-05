import Foundation
import SwiftUI
import Combine

enum PinExpiryOption: String, CaseIterable, Identifiable, Hashable, Codable {
    case oneHour, twoHours, fourHours, tenHours, twentyFourHours, threeDays, never
    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneHour: "1 hr"
        case .twoHours: "2 hrs"
        case .fourHours: "4 hrs"
        case .tenHours: "10 hrs"
        case .twentyFourHours: "24 hrs"
        case .threeDays: "3 days"
        case .never: "Never"
        }
    }

    var ttlSeconds: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .twoHours: 7200
        case .fourHours: 14400
        case .tenHours: 36000
        case .twentyFourHours: 86400
        case .threeDays: 259200
        case .never: nil
        }
    }
}

@MainActor
final class RadioGroupPinSettings: ObservableObject {
    private let key = "radioGroup_pinExpiryOption"

    @Published var expiry: PinExpiryOption {
        didSet { UserDefaults.standard.set(expiry.rawValue, forKey: key) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: key),
           let v = PinExpiryOption(rawValue: raw) {
            expiry = v
        } else {
            expiry = .tenHours
        }
    }
}
