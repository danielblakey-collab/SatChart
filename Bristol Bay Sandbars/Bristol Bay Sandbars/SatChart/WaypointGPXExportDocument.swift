import Foundation
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct WaypointGPXExportDocument: FileDocument {
    static let gpxContentType = UTType(exportedAs: "com.topografix.gpx")
    static var readableContentTypes: [UTType] { [gpxContentType, .xml] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum WaypointGPXBuilder {
    static func makeData(for waypoints: [Waypoint]) -> Data {
        Data(makeXML(for: waypoints).utf8)
    }

    static func makeXML(for waypoints: [Waypoint]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="SatChart" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
            "    <name>SatChart Waypoints</name>",
            "    <time>\(formatter.string(from: Date()))</time>",
            "  </metadata>"
        ]

        for waypoint in waypoints {
            let name = sanitizedWaypointName(waypoint.name)
            let notes = waypoint.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = formatter.string(from: waypoint.createdAt)
            var descriptionParts: [String] = []
            if !notes.isEmpty {
                descriptionParts.append(notes)
            }
            descriptionParts.append("Created \(created)")
            descriptionParts.append("SatChart")
            let description = descriptionParts.joined(separator: " | ")

            lines.append(String(format: #"  <wpt lat="%.8f" lon="%.8f">"#, waypoint.coordinate.latitude, waypoint.coordinate.longitude))
            lines.append("    <name>\(xmlEscaped(name))</name>")
            lines.append("    <desc>\(xmlEscaped(description))</desc>")
            lines.append("    <time>\(created)</time>")
            lines.append("    <sym>Waypoint</sym>")
            lines.append("  </wpt>")
        }

        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func defaultFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "satchart_waypoints_\(formatter.string(from: now))"
    }

    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func sanitizedWaypointName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Waypoint" : trimmed
        return String(name.prefix(64))
    }
}
