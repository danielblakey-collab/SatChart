import Foundation

enum WaypointLocalStore {
    nonisolated static func storageDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("SatChart", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    nonisolated static func storageURL() -> URL {
        storageDirectoryURL().appendingPathComponent("waypoints.json")
    }

    static func load(defaultColorID: String? = nil) -> [Waypoint] {
        let url = storageURL()
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var waypoints = try? decoder.decode([Waypoint].self, from: data) else {
            return []
        }

        let fallback = WaypointPinColor.safe(
            rawValue: defaultColorID,
            fallback: WaypointColorPreferences.ensureLocalDefaultColor()
        )
        var didNormalize = false
        for index in waypoints.indices {
            if WaypointPinColor(rawValue: waypoints[index].colorID) == nil {
                waypoints[index].colorID = fallback.rawValue
                didNormalize = true
            }
        }

        if didNormalize {
            save(waypoints)
        }

        return waypoints
    }

    static func save(_ waypoints: [Waypoint]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(waypoints)
            try data.write(to: storageURL(), options: [.atomic])
        } catch {
            #if DEBUG
            print("WaypointLocalStore save failed: \(error.localizedDescription)")
            #endif
        }
    }
}
