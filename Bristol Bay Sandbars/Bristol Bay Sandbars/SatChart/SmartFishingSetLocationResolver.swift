import Foundation
import CoreLocation

enum SmartFishingSetLocationKind: String, Codable, Equatable {
    case district
    case section
    case tideStation
    case noaaStation
    case landmark
    case coordinate

    // Legacy raw values from earlier builds. Keep these so existing
    // smart_logbook.json files decode instead of failing on old records.
    case districtAnchor
    case coordinateOnly
}

struct SmartFishingSetResolvedLocation: Equatable {
    let label: String
    let kind: SmartFishingSetLocationKind
    let districtKey: String?
}

struct SmartFishingSetLocationResolver {
    static let shared = SmartFishingSetLocationResolver()

    private let namedRegions: [NamedRegion]
    private let landmarks: [Landmark]

    init(bundle: Bundle = .main) {
        namedRegions = Self.loadNamedRegions(from: bundle)
        landmarks = Self.defaultLandmarks
    }

    func resolve(
        startCoordinate: CLLocationCoordinate2D,
        tideSnapshot: SmartFishingSetTideSnapshot?
    ) -> SmartFishingSetResolvedLocation {
        if let region = namedRegions.first(where: { $0.contains(startCoordinate) }) {
            return SmartFishingSetResolvedLocation(
                label: region.label,
                kind: region.kind,
                districtKey: region.districtKey
            )
        }

        let nearestLandmark = nearestLandmark(to: startCoordinate)

        if let tideSnapshot,
           let stationLabel = Self.normalizedLabel(from: tideSnapshot.stationName) {
            let distanceText = tideSnapshot.stationDistanceMiles.map { String(format: "%.1f mi", $0) }
            let label = [stationLabel, distanceText].compactMap { $0 }.joined(separator: " • ")

            return SmartFishingSetResolvedLocation(
                label: label,
                kind: tideSnapshot.stationID == nil ? .tideStation : .noaaStation,
                districtKey: Self.districtKey(from: stationLabel) ?? nearestLandmark?.districtKey
            )
        }

        if let nearestLandmark {
            return SmartFishingSetResolvedLocation(
                label: nearestLandmark.label,
                kind: .landmark,
                districtKey: nearestLandmark.districtKey
            )
        }

        return SmartFishingSetResolvedLocation(
            label: Self.coordinateLabel(for: startCoordinate),
            kind: .coordinate,
            districtKey: nil
        )
    }

    private func nearestLandmark(to coordinate: CLLocationCoordinate2D) -> Landmark? {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return landmarks.min { lhs, rhs in
            let left = origin.distance(from: CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude))
            let right = origin.distance(from: CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude))
            return left < right
        }
    }

    private static func coordinateLabel(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func normalizedLabel(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadNamedRegions(from bundle: Bundle) -> [NamedRegion] {
        var regions = loadBoundaryRegions(from: bundle)
        regions.append(contentsOf: loadAOIRegions(from: bundle))
        return regions.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.approximateArea != rhs.approximateArea { return lhs.approximateArea < rhs.approximateArea }
            return lhs.label < rhs.label
        }
    }

    private static func loadBoundaryRegions(from bundle: Bundle) -> [NamedRegion] {
        guard let url = bundle.url(forResource: "District_Boundaries_Final", withExtension: "geojson") else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
            return collection.features.compactMap { feature in
                guard let metadata = metadata(for: feature.properties) else { return nil }
                guard let polygons = polygons(from: feature.geometry), !polygons.isEmpty else { return nil }
                return NamedRegion(
                    label: metadata.label,
                    districtKey: metadata.districtKey,
                    kind: metadata.kind,
                    polygons: polygons
                )
            }
        } catch {
            #if DEBUG
            print("⚠️ SmartFishingSetLocationResolver boundary load failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    private static func loadAOIRegions(from bundle: Bundle) -> [NamedRegion] {
        let aoiFiles: [(name: String, districtKey: String, label: String)] = [
            ("aoi_ugashik", "ugashik", "Ugashik District"),
            ("aoi_egegik", "egegik", "Egegik District"),
            ("aoi_naknek_kvichak", "naknek_kvichak", "Naknek-Kvichak District"),
            ("aoi_nushagak", "nushagak", "Nushagak District"),
            ("aoi_togiak", "togiak", "Togiak District")
        ]

        return aoiFiles.compactMap { file -> NamedRegion? in
            let url = bundle.url(forResource: file.name, withExtension: "geojson", subdirectory: "AOI")
                ?? bundle.url(forResource: file.name, withExtension: "geojson")
            guard let url else { return nil }

            do {
                let data = try Data(contentsOf: url)
                let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
                let resolvedPolygons = collection.features.compactMap { Self.polygons(from: $0.geometry) }.flatMap { $0 }
                guard !resolvedPolygons.isEmpty else { return nil }
                return NamedRegion(
                    label: file.label,
                    districtKey: file.districtKey,
                    kind: .district,
                    polygons: resolvedPolygons
                )
            } catch {
                #if DEBUG
                print("⚠️ SmartFishingSetLocationResolver AOI load failed for \(file.name): \(error.localizedDescription)")
                #endif
                return nil
            }
        }
    }

    private static func metadata(for properties: [String: String]) -> (label: String, districtKey: String?, kind: SmartFishingSetLocationKind)? {
        let sectionLabel = firstNonEmptyValue(
            in: properties,
            keys: ["section_name", "sectionName", "section", "sectionlabel", "sectionLabel"]
        )
        let districtLabel = firstNonEmptyValue(
            in: properties,
            keys: ["district_name", "districtName", "district", "districtlabel", "districtLabel"]
        )
        let genericLabel = firstNonEmptyValue(
            in: properties,
            keys: ["label", "name", "Name", "title"]
        )
        let propertyDistrictKey = firstNonEmptyValue(
            in: properties,
            keys: ["district_key", "districtKey", "key"]
        ).flatMap { Self.districtKey(from: $0) }

        if let sectionLabel = normalizedLabel(from: sectionLabel) {
            return (sectionLabel, propertyDistrictKey ?? Self.districtKey(from: sectionLabel), .section)
        }
        if let districtLabel = normalizedLabel(from: districtLabel) {
            return (districtLabel, propertyDistrictKey ?? Self.districtKey(from: districtLabel), .district)
        }
        if let genericLabel = normalizedLabel(from: genericLabel) {
            let inferredKey = propertyDistrictKey ?? Self.districtKey(from: genericLabel)
            let kind: SmartFishingSetLocationKind = genericLabel.localizedCaseInsensitiveContains("section") ? .section : .district
            return (genericLabel, inferredKey, kind)
        }
        return nil
    }

    private static func firstNonEmptyValue(in properties: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func districtKey(from raw: String) -> String? {
        let normalized = raw.lowercased()
        if normalized.contains("naknek") || normalized.contains("kvichak") { return "naknek_kvichak" }
        if normalized.contains("egegik") { return "egegik" }
        if normalized.contains("ugashik") { return "ugashik" }
        if normalized.contains("nushagak") || normalized.contains("igushik") || normalized.contains("snake") { return "nushagak" }
        if normalized.contains("togiak") || normalized.contains("kulukak") || normalized.contains("matogak") || normalized.contains("osviak") || normalized.contains("peirce") {
            return "togiak"
        }
        return nil
    }

    private static func polygons(from geometry: GeoJSONGeometry?) -> [PolygonRegion]? {
        guard let geometry else { return nil }

        switch geometry {
        case .polygon(let rings):
            let polygons = polygonRegions(from: rings)
            return polygons.isEmpty ? nil : polygons
        case .multiPolygon(let polygons):
            let resolved = polygons.flatMap { polygonRegions(from: $0) }
            return resolved.isEmpty ? nil : resolved
        case .lineString(let coordinates):
            let polygons = polygonRegions(fromClosedSegments: [coordinates])
            return polygons.isEmpty ? nil : polygons
        case .multiLineString(let segments):
            let polygons = polygonRegions(fromClosedSegments: segments)
            return polygons.isEmpty ? nil : polygons
        }
    }

    private static func polygonRegions(from rings: [[[Double]]]) -> [PolygonRegion] {
        guard let outerRing = rings.first,
              let outer = smartFishingSetCoordinates(from: outerRing),
              outer.count >= 3 else {
            return []
        }
        let holes = rings.dropFirst().compactMap { smartFishingSetCoordinates(from: $0) }
        return [PolygonRegion(outer: outer, holes: holes)]
    }

    private static func polygonRegions(fromClosedSegments segments: [[[Double]]]) -> [PolygonRegion] {
        let resolvedSegments = segments.compactMap { smartFishingSetCoordinates(from: $0) }
        let rings = assembleClosedRings(from: resolvedSegments)
        return rings.compactMap { ring in
            guard ring.count >= 3 else { return nil }
            return PolygonRegion(outer: ring, holes: [])
        }
    }

    private static func assembleClosedRings(from segments: [[CLLocationCoordinate2D]]) -> [[CLLocationCoordinate2D]] {
        var remaining = segments.filter { !$0.isEmpty }
        var rings: [[CLLocationCoordinate2D]] = []

        while !remaining.isEmpty {
            var candidate = remaining.removeFirst()
            var didAppend = true

            while didAppend {
                didAppend = false

                for index in remaining.indices.reversed() {
                    let next = remaining[index]
                    guard let candidateFirst = candidate.first, let candidateLast = candidate.last,
                          let nextFirst = next.first, let nextLast = next.last else {
                        continue
                    }

                    if pointsAreNear(candidateLast, nextFirst) {
                        candidate.append(contentsOf: next.dropFirst())
                        remaining.remove(at: index)
                        didAppend = true
                    } else if pointsAreNear(candidateLast, nextLast) {
                        candidate.append(contentsOf: next.reversed().dropFirst())
                        remaining.remove(at: index)
                        didAppend = true
                    } else if pointsAreNear(candidateFirst, nextLast) {
                        candidate.insert(contentsOf: next.dropLast(), at: 0)
                        remaining.remove(at: index)
                        didAppend = true
                    } else if pointsAreNear(candidateFirst, nextFirst) {
                        candidate.insert(contentsOf: next.reversed().dropLast(), at: 0)
                        remaining.remove(at: index)
                        didAppend = true
                    }
                }
            }

            if let first = candidate.first,
               let last = candidate.last,
               pointsAreNear(first, last),
               candidate.count >= 4 {
                candidate[candidate.count - 1] = first
                rings.append(candidate)
            }
        }

        return rings
    }

    private static func pointsAreNear(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        abs(lhs.latitude - rhs.latitude) < 0.0005 && abs(lhs.longitude - rhs.longitude) < 0.0005
    }

    private static let defaultLandmarks: [Landmark] = [
        Landmark(label: "Pilot Point, AK", districtKey: "ugashik", coordinate: CLLocationCoordinate2D(latitude: 57.564, longitude: -157.572)),
        Landmark(label: "Ugashik Bay", districtKey: "ugashik", coordinate: CLLocationCoordinate2D(latitude: 57.550, longitude: -157.670)),
        Landmark(label: "Egegik Bay", districtKey: "egegik", coordinate: CLLocationCoordinate2D(latitude: 58.220, longitude: -157.370)),
        Landmark(label: "Naknek-Kvichak Bay", districtKey: "naknek_kvichak", coordinate: CLLocationCoordinate2D(latitude: 58.740, longitude: -156.880)),
        Landmark(label: "Clarks Point, AK", districtKey: "nushagak", coordinate: CLLocationCoordinate2D(latitude: 58.840, longitude: -158.530)),
        Landmark(label: "Togiak Bay", districtKey: "togiak", coordinate: CLLocationCoordinate2D(latitude: 59.060, longitude: -160.370)),
        Landmark(label: "Cape Peirce", districtKey: "togiak", coordinate: CLLocationCoordinate2D(latitude: 58.450, longitude: -161.790))
    ]
}

extension SmartFishingSetRecord {
    var startCoordinate: CLLocationCoordinate2D? {
        sortedLocations.first?.coordinate
    }

    func resolvedSetLocation(using resolver: SmartFishingSetLocationResolver = .shared) -> SmartFishingSetResolvedLocation? {
        if let startCoordinate {
            return resolver.resolve(startCoordinate: startCoordinate, tideSnapshot: startTide)
        }

        let trimmedStored = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedStored.isEmpty else { return nil }

        return SmartFishingSetResolvedLocation(
            label: trimmedStored,
            kind: locationKind ?? .coordinate,
            districtKey: locationDistrictKey
        )
    }

    var displayLocationLabel: String {
        let trimmedStored = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedStored.isEmpty { return trimmedStored }
        return resolvedSetLocation()?.label ?? "Location unavailable"
    }
}

private struct Landmark {
    let label: String
    let districtKey: String?
    let coordinate: CLLocationCoordinate2D
}

private func smartFishingSetCoordinates(from rawCoordinates: [[Double]]) -> [CLLocationCoordinate2D]? {
    let coordinates = rawCoordinates.compactMap { pair -> CLLocationCoordinate2D? in
        guard pair.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
    }
    return coordinates.isEmpty ? nil : coordinates
}

private struct NamedRegion {
    let label: String
    let districtKey: String?
    let kind: SmartFishingSetLocationKind
    let polygons: [PolygonRegion]

    var approximateArea: Double {
        polygons.reduce(0) { partial, polygon in
            partial + polygon.boundingBoxArea
        }
    }

    var priority: Int {
        switch kind {
        case .section:
            return 0
        case .district:
            return 1
        default:
            return 2
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        polygons.contains { $0.contains(coordinate) }
    }
}

private struct PolygonRegion {
    let outer: [CLLocationCoordinate2D]
    let holes: [[CLLocationCoordinate2D]]

    var boundingBoxArea: Double {
        let latitudes = outer.map(\.latitude)
        let longitudes = outer.map(\.longitude)
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max() else {
            return .greatestFiniteMagnitude
        }
        return abs((maxLat - minLat) * (maxLon - minLon))
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard Self.pointInRing(coordinate, ring: outer) else { return false }
        return !holes.contains(where: { Self.pointInRing(coordinate, ring: $0) })
    }

    private static func pointInRing(_ point: CLLocationCoordinate2D, ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count >= 3 else { return false }
        var contains = false
        var previous = ring.last!

        for current in ring {
            let intersects = ((current.latitude > point.latitude) != (previous.latitude > point.latitude))
                && (point.longitude < (previous.longitude - current.longitude)
                    * (point.latitude - current.latitude)
                    / ((previous.latitude - current.latitude) == 0 ? .leastNonzeroMagnitude : (previous.latitude - current.latitude))
                    + current.longitude)

            if intersects {
                contains.toggle()
            }

            previous = current
        }

        return contains
    }
}

private struct GeoJSONFeatureCollection: Decodable {
    let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Decodable {
    let properties: [String: String]
    let geometry: GeoJSONGeometry?

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        geometry = try container.decodeIfPresent(GeoJSONGeometry.self, forKey: DynamicCodingKey(stringValue: "geometry")!)

        if let propertiesContainer = try? container.nestedContainer(
            keyedBy: DynamicCodingKey.self,
            forKey: DynamicCodingKey(stringValue: "properties")!
        ) {
            var resolved: [String: String] = [:]
            for key in propertiesContainer.allKeys {
                if let value = try? propertiesContainer.decode(String.self, forKey: key) {
                    resolved[key.stringValue] = value
                } else if let value = try? propertiesContainer.decode(Int.self, forKey: key) {
                    resolved[key.stringValue] = String(value)
                } else if let value = try? propertiesContainer.decode(Double.self, forKey: key) {
                    resolved[key.stringValue] = String(value)
                }
            }
            properties = resolved
        } else {
            properties = [:]
        }
    }
}

private enum GeoJSONGeometry: Decodable {
    case polygon([[[Double]]])
    case multiPolygon([[[[Double]]]])
    case lineString([[Double]])
    case multiLineString([[[Double]]])

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "Polygon":
            self = .polygon(try container.decode([[[Double]]].self, forKey: .coordinates))
        case "MultiPolygon":
            self = .multiPolygon(try container.decode([[[[Double]]]].self, forKey: .coordinates))
        case "LineString":
            self = .lineString(try container.decode([[Double]].self, forKey: .coordinates))
        case "MultiLineString":
            self = .multiLineString(try container.decode([[[Double]]].self, forKey: .coordinates))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported GeoJSON geometry type: \(type)"
            )
        }
    }
}
