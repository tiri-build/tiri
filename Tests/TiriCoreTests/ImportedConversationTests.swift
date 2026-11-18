import Foundation
import Testing
@testable import TiriCore

@Suite struct ImportedConversationTests {
    @Test func titlesUseReadableMarkdownAndSkipSpeakersAndCode() {
        #expect(ImportedConversations.title(for: "# **研究** [笔记](https://example.com)\n\n正文") == "研究 笔记")
        #expect(ImportedConversations.title(for: "# You\n\n如何保存对话？\n\n## ChatGPT\n\n可以复制 Markdown。") == "如何保存对话？")
        #expect(ImportedConversations.title(for: "```sh\n# not a heading\n```\n\nA **real** answer.") == "A real answer.")
        #expect(ImportedConversations.title(for: String(repeating: "长", count: 100)).count == 64)
        #expect(ImportedConversations.title(for: "```\ncode only\n```") == "Imported Markdown")
    }

    @Test func persistenceRenderingAndSearchPreserveTheWholePaste() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let markdown = "\n# 浏览器对话\n\nYou said:\n\n表格和代码\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet value = 42\n```\n\n" + String(repeating: "A long paragraph. ", count: 1000) + "\nneedle-at-the-end\n"
        let first = try ImportedConversations.save(markdown: markdown, root: root, cwd: "/work")
        let second = try ImportedConversations.save(markdown: markdown, root: root, cwd: nil)
        #expect(first.session != second.session)
        #expect(first.resumeCommand == nil)
        let loaded = ImportedConversations.load(root: root)
        #expect(loaded.count == 2)
        #expect(loaded.contains(first))
        let data = try Data(contentsOf: URL(fileURLWithPath: first.file))
        #expect(ImportedConversations.decode(data)?.markdown == markdown)
        #expect(Conversations.markdown(data, summary: first) == markdown)
        let text = try #require(Conversations.text(of: data, agent: first.agent))
        #expect(text.you.contains("needle-at-the-end"))
        #expect(Conversations.labelDigest(Conversations.turns(of: data, agent: first.agent)) != nil)
        let index = try ConversationIndex(path: root + "/search.sqlite")
        index.store(file: first.file, seconds: 1, title: first.title, place: first.cwd, text: text)
        #expect(index.search(words: ["needle-at-the-end"]).first?.file == first.file)
        #expect(index.search(words: ["浏览器"]).first?.file == first.file)
        try Data("broken".utf8).write(to: URL(fileURLWithPath: root + "/imports/broken.json"))
        #expect(ImportedConversations.load(root: root).count == 2)
        #expect(throws: ImportedConversations.Failure.self) {
            try ImportedConversations.save(markdown: " \n\t", root: root, cwd: nil)
        }
        #expect(ImportedConversations.load(root: root).count == 2)
    }
}
