import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? UTType(exportedAs: "com.topografix.gpx")
    static let satChartLogbookArchive = UTType(filenameExtension: "zip") ?? UTType(exportedAs: "com.satchart.logbook-archive")
}

struct LogbookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [
            .commaSeparatedText,
            .json,
            .xml,
            .gpx,
            .satChartLogbookArchive,
            .data
        ]
    }

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
