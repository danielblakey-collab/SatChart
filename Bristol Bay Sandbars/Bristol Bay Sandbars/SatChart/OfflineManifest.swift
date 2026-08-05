import Foundation

struct Manifest: Decodable {
    let schemaVersion: Int
    let packs: [Pack]
}

struct Pack: Decodable {
    let id: String
    let type: String
    let version: Int
    let format: String
    let url: String
    let sha256: String
    let size: Int
    let sqliteUrl: String?
    let sqliteSha256: String?
    let sqliteSize: Int?
}
