import Foundation

enum SimpleZipWriter {
    struct Entry {
        let path: String
        let data: Data
        var modifiedAt: Date = Date()
    }

    private struct CentralDirectoryEntry {
        let pathData: Data
        let crc: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    static func archive(entries: [Entry], maxArchiveBytes: Int64 = 512 * 1024 * 1024) throws -> Data {
        var archive = Data()
        var centralEntries: [CentralDirectoryEntry] = []

        for entry in entries {
            let normalizedPath = entry.path
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalizedPath.isEmpty else { continue }

            let pathData = Data(normalizedPath.utf8)
            guard pathData.count <= Int(UInt16.max) else {
                throw LogbookExportError.fileTooLarge("A ZIP filename is too long: \(normalizedPath)")
            }
            guard entry.data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
                throw LogbookExportError.fileTooLarge("The logbook archive is too large for the simple ZIP writer.")
            }
            if Int64(archive.count) + Int64(entry.data.count) > maxArchiveBytes {
                throw LogbookExportError.fileTooLarge("The selected archive is too large. Try excluding photos or receipts.")
            }

            let crc = CRC32.checksum(entry.data)
            let (dosTime, dosDate) = dosDateTime(from: entry.modifiedAt)
            let localOffset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            archive.appendUInt32LE(0x04034b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0x0800)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(dosTime)
            archive.appendUInt16LE(dosDate)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(size)
            archive.appendUInt32LE(size)
            archive.appendUInt16LE(UInt16(pathData.count))
            archive.appendUInt16LE(0)
            archive.append(pathData)
            archive.append(entry.data)

            centralEntries.append(
                CentralDirectoryEntry(
                    pathData: pathData,
                    crc: crc,
                    size: size,
                    localHeaderOffset: localOffset,
                    dosTime: dosTime,
                    dosDate: dosDate
                )
            )
        }

        guard centralEntries.count <= Int(UInt16.max), archive.count <= Int(UInt32.max) else {
            throw LogbookExportError.fileTooLarge("The selected archive has too many files.")
        }

        let centralDirectoryOffset = UInt32(archive.count)
        for entry in centralEntries {
            archive.appendUInt32LE(0x02014b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0x0800)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(entry.dosTime)
            archive.appendUInt16LE(entry.dosDate)
            archive.appendUInt32LE(entry.crc)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt16LE(UInt16(entry.pathData.count))
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(0)
            archive.appendUInt32LE(entry.localHeaderOffset)
            archive.append(entry.pathData)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(centralEntries.count))
        archive.appendUInt16LE(UInt16(centralEntries.count))
        archive.appendUInt32LE(centralDirectorySize)
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)

        return archive
    }

    private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(58, components.second ?? 0)) / 2

        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
