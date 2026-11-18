import Foundation
import Markdown

/// Pasted conversations live separately from agent-owned files. One atomic record preserves the source verbatim.
public enum ImportedConversations {
    public static let agent = "imported-markdown"

    public struct Record: Codable, Sendable {
        public var session: String
        public var title: String
        public var markdown: String
        public var date: Date
        public var cwd: String?

        public func summary(file: String) -> ConversationSummary {
            ConversationSummary(agent: ImportedConversations.agent, session: session, file: file, title: title, cwd: cwd, date: date)
        }
    }

    public enum Failure: LocalizedError {
        case empty
        public var errorDescription: String? { String(localized: "Paste some Markdown first.") }
    }

    public static func decode(_ data: Data) -> Record? { try? JSONDecoder().decode(Record.self, from: data) }

    public static func save(markdown: String, root: String, cwd: String?) throws -> ConversationSummary {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        let record = Record(session: UUID().uuidString.lowercased(), title: title(for: markdown), markdown: markdown, date: Date(), cwd: cwd)
        let folder = URL(fileURLWithPath: root).appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(record.session + ".json")
        try JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return record.summary(file: file.path)
    }

    public static func load(root: String) -> [ConversationSummary] {
        let folder = URL(fileURLWithPath: root).appendingPathComponent("imports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            // Directory enumeration may expand /var to /private/var; keep the same spelling as save.
            (try? Data(contentsOf: file)).flatMap(decode)?.summary(file: folder.appendingPathComponent(file.lastPathComponent).path)
        }.sorted { $0.date > $1.date }
    }

    /// A useful title even offline: the first real heading, otherwise the first prose line, with Markdown removed.
    public static func title(for markdown: String) -> String {
        let document = Document(parsing: String(markdown.prefix(32_000)))
        let speakers: Set<String> = ["you", "user", "assistant", "chatgpt", "you said:", "chatgpt said:", "你说：", "你說：", "chatgpt 说：", "chatgpt 說："]
        func candidate(_ value: String) -> String? {
            let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty, !speakers.contains(text.lowercased()) else { return nil }
            return text.count > 64 ? String(text.prefix(63)) + "…" : text
        }
        for child in document.children {
            if let heading = child as? Heading, let title = candidate(heading.plainText) { return title }
        }
        func prose(_ node: any Markup) -> String? {
            if let paragraph = node as? Paragraph, let title = candidate(paragraph.plainText) { return title }
            for child in node.children { if let title = prose(child) { return title } }
            return nil
        }
        return prose(document) ?? String(localized: "Imported Markdown")
    }
}
