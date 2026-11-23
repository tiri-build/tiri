import Foundation

enum Antigravity {
    static let profile = AgentProfile(
        id: "agy", title: "Antigravity", command: "agy", website: "https://antigravity.google", symbol: "arrow.up.circle",
        executableNames: ["agy"], pathFragments: [], mentionPrefix: "@", lineStyle: .colon, speaksEditorProtocol: false,
        continueCommand: "agy --continue", resumeCommand: "agy --conversation {id}",
        resumingFlags: ["-c", "--continue", "--conversation"], resumingSubcommands: [],
        oneShotFlags: ["-p", "--print", "--prompt"], oneShotSubcommands: ["acp", "help", "install", "plugin", "plugins", "agent", "agents", "models", "mcp", "update", "remote-control", "changelog", "mic-serve"],
        configDirectory: ".gemini/antigravity-cli", configDirectoryVariable: nil, hookInstall: nil,
        hookEvents: [], parseHook: nil, claimsHookPayload: nil, alsoRunsHooksOf: nil, hookExample: nil,
        conversationFiles: "brain/*/.system_generated/logs/transcript_full.jsonl", conversationFormat: .antigravity)

    static func session(_ file: String) -> String? {
        let folder = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let id = folder.lastPathComponent
        return UUID(uuidString: id) == nil ? nil : id
    }

    // The transcript has the turns. Its workspace and display title live in agy's summary database.
    static func startScript(_ file: Conversations.Found, maximumBytes: Int) -> String {
        guard let id = session(file.file) else { return "" }
        let path = ShellQuote.quote(file.file)
        let query = "SELECT json_object('title',title,'workspace',json_extract(workspace_uris,'$[0]')) FROM conversation_summaries WHERE conversation_id='\(id)'"
        return """
        printf '\\036%s\\t%s\\t%s\\n' agy \(file.seconds) \(path)
        agy_db="$HOME/.gemini/antigravity-cli/conversation_summaries.db"
        if [ -f "$agy_db" ]; then
            agy_query=\(ShellQuote.quote(query))
            # A closed WAL database may have no shared-memory file. Read its checkpoint in place.
            if ! sqlite3 -batch -readonly "$agy_db" "$agy_query" 2>/dev/null && [ ! -s "$agy_db-wal" ]; then
                sqlite3 -batch -readonly "file:$agy_db?immutable=1" "$agy_query" 2>/dev/null
            fi
        fi
        grep -a -m 1 -E '"type": ?"USER_INPUT"' \(path) | head -c \(maximumBytes)
        printf '\\n'

        """
    }

    static func prompt(_ step: [String: Any]) -> String? {
        guard step["type"] as? String == "USER_INPUT", let content = step["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<USER_REQUEST>", close = "</USER_REQUEST>"
        if trimmed.hasPrefix(open), let end = trimmed.range(of: close, options: .backwards) {
            return trimmed[trimmed.index(trimmed.startIndex, offsetBy: open.count)..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.hasPrefix("<ADDITIONAL_METADATA>") || trimmed.isEmpty ? nil : trimmed
    }

    static func pieces(_ step: [String: Any]) -> [Conversations.Piece] {
        if let text = prompt(step), !text.isEmpty { return [.you(text)] }
        guard step["type"] as? String == "PLANNER_RESPONSE" else { return [] }
        var pieces: [Conversations.Piece] = []
        if let text = step["content"] as? String, !text.isEmpty { pieces.append(.agent(text)) }
        for call in step["tool_calls"] as? [[String: Any]] ?? [] {
            guard let name = call["name"] as? String else { continue }
            let args = call["args"] as? [String: Any]
            let detail = args?["toolSummary"] as? String ?? args?["Path"] as? String ?? args?["CommandLine"] as? String
            pieces.append(.did(detail.map { name + " · " + $0 } ?? name))
        }
        return pieces
    }
}
