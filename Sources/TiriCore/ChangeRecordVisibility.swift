import Foundation

/// List-only deletions: keep the commits available for updates and recovery.
public struct ChangeRecordVisibility: Sendable {
    public static var file: URL { YourTiri.root.appendingPathComponent("deleted-change-records.json") }
    public private(set) var deleted: Set<String>

    public init(file: URL = Self.file) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            deleted = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
        } else {
            deleted = []
        }
    }

    public func visible(_ changes: [PersonalChange]) -> [PersonalChange] {
        changes.filter { !deleted.contains($0.id) }
    }

    public mutating func delete(_ id: String, file: URL = Self.file) throws {
        var next = deleted
        next.insert(id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DurableFile.write(JSONEncoder().encode(next.sorted()), to: file)
        deleted = next
    }
}
