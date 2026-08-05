import Foundation

enum CSVWriter {
    nonisolated static func escape(_ raw: String) -> String {
        let needsQuoting = raw.contains(",")
            || raw.contains("\"")
            || raw.contains("\n")
            || raw.contains("\r")

        guard needsQuoting else { return raw }
        return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated static func line(_ fields: [String]) -> String {
        fields.map { escape($0) }.joined(separator: ",") + "\n"
    }

    nonisolated static func data(rows: [[String]]) -> Data {
        Data(rows.map { line($0) }.joined().utf8)
    }
}

enum XMLWriter {
    nonisolated static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    nonisolated static func sanitizedName(_ raw: String, maxLength: Int) -> String {
        let collapsed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
