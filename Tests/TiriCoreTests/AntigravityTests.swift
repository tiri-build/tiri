import Foundation
import Testing
@testable import TiriCore

@Suite struct AntigravityTests {
    @Test func adoptsAnExistingLauncher() throws {
        let preset = TerminalPreset(name: "My AGY", command: "/opt/bin/agy --model fast", isEnabled: false)
        let adopted = AgentCatalog.adopting(into: [preset], resume: [:], known: ["claude", "codex", "grok"])
        #expect(adopted.presets == [preset])
        let entry = try #require(AgentRoster.find("agy", in: adopted.presets))
        #expect(!entry.isCustom)
        #expect(!entry.isEnabled)
        #expect(entry.profile?.hookInstall == nil)
        #expect(adopted.resume["agy"] == "agy --continue")
    }

    @Test func readsTheOriginalTranscript() throws {
        let session = UUID().uuidString.lowercased()
        let path = "/tmp/brain/\(session)/.system_generated/logs/transcript_full.jsonl"
        let transcript = Data(#"""
        {"type":"USER_INPUT","content":"<USER_REQUEST>\n看下项目\n</USER_REQUEST>\n<ADDITIONAL_METADATA>metadata</ADDITIONAL_METADATA>"}
        {"type":"PLANNER_RESPONSE","thinking":"private","tool_calls":[{"name":"read_file","args":{"Path":"README.md"}}]}
        {"type":"GENERIC","content":"tool output"}
        {"type":"PLANNER_RESPONSE","content":"项目说明"}
        """#.utf8)
        let head = Data(#"{"title":"Overview","workspace":"file:///tmp/my%20project"}"#.utf8) + Data([10]) + transcript
        let summary = try #require(Conversations.summary(agent: "agy", file: path, date: Date(), head: head))
        #expect(summary.cwd == "/tmp/my project")
        #expect(summary.title == "Overview")
        #expect(summary.resumeCommand == "agy --conversation \(session)")
        #expect(Conversations.summary(agent: "agy", file: path, date: Date(), head: transcript)?.title == "看下项目")
        let text = try #require(Conversations.text(of: transcript, agent: "agy"))
        #expect(text.you == "看下项目\n")
        #expect(text.agent == "项目说明\n")
        #expect(text.did.contains("README.md"))
        #expect(Conversations.markdown(transcript, summary: summary).contains("## Antigravity"))
    }
}
