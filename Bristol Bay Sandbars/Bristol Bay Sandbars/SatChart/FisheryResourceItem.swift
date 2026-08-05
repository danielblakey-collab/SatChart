import Foundation

struct FisheryResourceItem: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var subtitle: String?
    var urlString: String
    var sourceName: String
    var sourceURLString: String?
    var category: FisheryResourceCategory
    var documentType: String?
    var year: Int?
    var seasonYear: Int?
    var districtKeys: [String]
    var publishedAt: Date?
    var fetchedAt: Date?
    var sortOrder: Int
    var active: Bool
    var isOfficialSource: Bool
    var notes: String?
    var releaseType: String?

    var url: URL? {
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        return url
    }

    var sourceURL: URL? {
        guard let sourceURLString,
              let url = URL(string: sourceURLString),
              url.scheme != nil else {
            return nil
        }
        return url
    }
}
