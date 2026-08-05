import Foundation

enum DeepResearchBetaError {
    static func debugLog(_ error: Error, context: String) {
        #if DEBUG
        print("\(context) failed: \(error)")
        #endif
    }

    static func userFacingMessage(for error: Error, feature: String = "Deep Research") -> String {
        let rawMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        if rawMessage.isEmpty {
            return genericMessage(feature: feature)
        }

        if isDeveloperDatabaseMessage(rawMessage) {
            return genericMessage(feature: feature)
        }

        return rawMessage
    }

    static func genericMessage(feature: String) -> String {
        "\(feature) could not load from the installed beta data pack. Open Beta Diagnostics in Settings to verify offline data, then reinstall or update SatChart if any critical check fails."
    }

    private static func isDeveloperDatabaseMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        let rawTokens = [
            "sqlite",
            "sql",
            "grdb",
            "databaseerror",
            "no such table",
            "no such column",
            "constraint failed",
            "pragma",
            "offline db",
            "offline database required table",
            "missing required table"
        ]

        return rawTokens.contains { text.contains($0) }
    }
}
