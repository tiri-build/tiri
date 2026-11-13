import AppKit
import SwiftUI
import TiriCore

// MARK: - The model's side

/// The note being written, wherever it is. One at a time: opening another keeps what was typed in the first.
@MainActor @Observable final class NoteWriting {
    static let shared = NoteWriting()

    struct Open: Equatable {
        var item: ItemID
        var anchor: ReviewAnchor
        /// The note being changed, when it isn't a new one.
        var editing: String?
        /// Where the thing is in the item's note layer, for a box beside it. Nil when the box sits in the text itself.
        var rect: NSRect?
    }

    var open: Open?
    var text = ""
    /// Items where pointing is switched on, until Esc or the button.
    var pointing: Set<ItemID> = []
    /// Sent notes whose lines an agent has since changed.
    var changed: Set<String> = []
    /// What was typed for something and not added, by what it was on.
    @ObservationIgnored var drafts: [String: String] = [:]

    static func key(_ anchor: ReviewAnchor) -> String {
        var parts = [anchor.path, anchor.commit ?? ""]
        if let first = anchor.firstLine { parts.append("\(first)-\(anchor.lastLine ?? first)") }
        if let spot = anchor.spot {
            parts.append(spot.selector ?? "")
            parts.append("\(Int(spot.x ?? -1)),\(Int(spot.y ?? -1)),\(spot.page ?? 0)")
        }
        if anchor.firstLine == nil, anchor.spot == nil, let quote = anchor.quote { parts.append(String(quote.prefix(80))) }
        return parts.joined(separator: "|")
    }
}

extension AppModel {
    /// ⌥⌘L. A note on what's selected in front, or the line the cursor is in. Where there are no lines, it turns pointing on.
    func beginReviewComment() {
        guard let item = active.peek ?? active.activeItem, let controller = existingController(for: item.id) else { return }
        if let anchor = controller.reviewAnchor {
            let place = controller.reviewPopoverPosition.map { NoteLayer.rect($0.rect, of: $0.view, in: controller.view) }
            beginNote(anchor, in: item.id, at: place)
            return
        }
        if controller is NoteSurface, (controller as? NoteSurface)?.canPoint == true {
            togglePointing(item.id)
            return
        }
        if case .file(let spec) = item.content, controller is NoteSurface {
            beginNote(ReviewAnchor(path: spec.path), in: item.id, at: nil)
            return
        }
        showToast(title: String(localized: "There's nothing to note here"), detail: String(localized: "Open a file, a diff, a page or a picture, then press ⌥⌘L."), symbol: "text.bubble", tint: .secondary)
    }

    func beginNote(_ anchor: ReviewAnchor, in item: ItemID, at rect: NSRect?) {
        let writing = NoteWriting.shared
        closeNote()
        writing.text = writing.drafts[NoteWriting.key(anchor)] ?? ""
        writing.open = NoteWriting.Open(item: item, anchor: anchor, editing: nil, rect: rect)
        reviewDidChange()
    }

    func editNote(_ comment: ReviewComment, in item: ItemID, at rect: NSRect?) {
        let writing = NoteWriting.shared
        closeNote()
        let anchor = ReviewAnchor(path: comment.path, firstLine: comment.firstLine, lastLine: comment.lastLine, excerpt: comment.excerpt,
                                  quote: comment.quote, quoteIsDiff: comment.quoteIsDiff, commit: comment.commit, spot: comment.spot)
        writing.text = comment.text
        writing.open = NoteWriting.Open(item: item, anchor: anchor, editing: comment.id, rect: rect)
        reviewDidChange()
    }

    /// A press on a note's mark: the note opens where it is.
    func editNote(_ comment: ReviewComment, in item: ItemID) {
        let rect = (existingController(for: item) as? NoteSurface).flatMap { _ in NoteLayer.existing(for: item)?.rect(of: comment.id) }
        editNote(comment, in: item, at: rect)
    }

    /// Return in the box. With `sending`, ⌘↩: it's added and the waiting notes go to the agent's input.
    func commitNote(sending: Bool = false) {
        let writing = NoteWriting.shared
        guard let open = writing.open else { return }
        let text = writing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pointing at something says which thing. Lines need the words too.
        let pointsAtSomething = open.anchor.spot != nil || open.anchor.quote != nil
        guard !text.isEmpty || (sending && pointsAtSomething) else { return }
        writing.drafts[NoteWriting.key(open.anchor)] = nil
        writing.open = nil
        writing.text = ""
        if let id = open.editing {
            updateReviewComment(id, text: text)
        } else {
            addReviewComment(open.anchor.comment(text: text), in: workspace(containing: open.item)?.id)
        }
        existingController(for: open.item)?.focus()
        if sending { sendReview() }
    }

    /// Esc, or opening another. What was typed is kept for the same place.
    func closeNote() {
        let writing = NoteWriting.shared
        guard let open = writing.open else { return }
        if open.editing == nil {
            let typed = writing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            writing.drafts[NoteWriting.key(open.anchor)] = typed.isEmpty ? nil : writing.text
        }
        writing.open = nil
        writing.text = ""
        reviewDidChange()
        existingController(for: open.item)?.focus()
    }

    func removeOpenNote() {
        guard let id = NoteWriting.shared.open?.editing else { return }
        let item = NoteWriting.shared.open?.item
        NoteWriting.shared.open = nil
        NoteWriting.shared.text = ""
        removeReviewComment(id)
        if let item { existingController(for: item)?.focus() }
    }

    /// The button, and ⌥⌘L where there are no lines: the next click notes what it's on, until Esc.
    func togglePointing(_ item: ItemID? = nil) {
        guard let id = item ?? (active.peek ?? active.activeItem)?.id else { return }
        let writing = NoteWriting.shared
        if writing.pointing.contains(id) { writing.pointing.remove(id) } else { writing.pointing.insert(id) }
        NoteLayer.existing(for: id)?.pointingChanged()
    }

    func isPointing(_ item: ItemID) -> Bool { NoteWriting.shared.pointing.contains(item) }

    /// How many notes would go with a message from this terminal.
    func notesWaiting(for terminal: ItemID) -> Int { (workspace(containing: terminal) ?? active).pendingNotes.count }

    /// The number on a waiting note's mark, wherever its workspace is.
    func noteNumber(_ id: String) -> Int? {
        for workspace in workspaces {
            if let number = workspace.noteNumber(id) { return number }
        }
        return nil
    }

    func addReviewComment(_ comment: ReviewComment, in workspaceID: WorkspaceID? = nil) {
        update(workspace: workspaceID ?? activeID) { $0.review.append(comment) }
        SidebarSection.review.open()
        scheduleSave()
        reviewDidChange()
        hintAtSendingNotes()
    }

    /// Once: a note that's been added says nothing about where it goes next.
    private func hintAtSendingNotes() {
        let key = "notes.sendHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let keys = shortcutSymbol(for: "sendReview") ?? "⌥⇧⌘L"
        showToast(title: String(localized: "Your note is waiting"), detail: String(localized: "Add more, then send them together: \(keys), or with your next message in Write to Agent."),
                  symbol: "text.bubble", tint: .accentColor, actionTitle: String(localized: "Send Now")) { [weak self] in self?.sendReview() }
    }

    func updateReviewComment(_ id: String, text: String) {
        for workspace in workspaces where workspace.review.contains(where: { $0.id == id }) {
            update(workspace: workspace.id) { workspace in
                guard let index = workspace.review.firstIndex(where: { $0.id == id }) else { return }
                workspace.review[index].text = text
            }
        }
        scheduleSave()
        reviewDidChange()
    }

    func removeReviewComment(_ id: String) {
        for workspace in workspaces where workspace.review.contains(where: { $0.id == id }) {
            update(workspace: workspace.id) { $0.review.removeAll { $0.id == id } }
        }
        NoteWriting.shared.changed.remove(id)
        scheduleSave()
        reviewDidChange()
    }

    func discardReview() {
        let old = active.review
        guard !old.isEmpty else { return }
        updateActive { $0.review = [] }
        scheduleSave()
        reviewDidChange()
        let title = old.count == 1 ? String(localized: "1 note discarded") : String(localized: "\(old.count) notes discarded")
        showToast(title: title, detail: nil, symbol: "trash", tint: .secondary, actionTitle: String(localized: "Undo")) { [weak self] in
            self?.updateActive { $0.review = old }
            self?.scheduleSave()
            self?.reviewDidChange()
        }
    }

    /// Sent notes stay on screen to check the answer against. This takes them away.
    func clearSentNotes() {
        let sent = Set(active.review.filter { $0.sent != nil }.map(\.id))
        guard !sent.isEmpty else { return }
        updateActive { $0.review.removeAll { sent.contains($0.id) } }
        NoteWriting.shared.changed.subtract(sent)
        scheduleSave()
        reviewDidChange()
    }

    /// With one agent running they go straight there. With several, you choose.
    func sendReview() {
        guard !active.pendingNotes.isEmpty else {
            showToast(title: String(localized: "There are no notes to send"), detail: String(localized: "Click the + beside a line, or press ⌥⌘L on what you mean."), symbol: "text.bubble", tint: .secondary)
            return
        }
        let count = active.pendingNotes.count
        let question = count == 1 ? String(localized: "Which session should get 1 note?") : String(localized: "Which session should get \(count) notes?")
        withAgent(asking: question) { [weak self] terminal, _ in
            self?.deliverReview(to: terminal)
        }
    }

    @discardableResult
    func sendReview(to item: ItemID) -> Bool {
        guard let session = activeAgentSessions().first(where: { $0.item.id == item }) else { return false }
        deliverReview(to: session.terminal)
        return true
    }

    /// The waiting notes as a message, for a terminal in this folder. Their pictures come apart from the words.
    func notesMessage(for terminal: TerminalController) -> (ids: [String], parts: ReviewMessage.Parts)? {
        let notes = (workspace(containing: terminal.itemID) ?? active).pendingNotes
        guard !notes.isEmpty else { return nil }
        // A terminal reports real paths, and the workspace may know a folder by a link to it.
        let real = notes.map { note in
            var note = note
            // A page that isn't a file is filed under its address, which has no place on disk to look for.
            if note.path.hasPrefix("/") { note.path = Git.real(note.path) }
            return note
        }
        return (notes.map(\.id), ReviewMessage.parts(comments: real, cwd: Git.real(terminal.currentDirectory)))
    }

    /// They've gone to an agent. They stay where they were made, as sent.
    func notesWereSent(_ ids: [String]) {
        let sent = Set(ids)
        let now = Date()
        for workspace in workspaces where workspace.review.contains(where: { sent.contains($0.id) }) {
            update(workspace: workspace.id) { workspace in
                for index in workspace.review.indices where sent.contains(workspace.review[index].id) { workspace.review[index].sent = now }
            }
        }
        scheduleSave()
        reviewDidChange()
    }

    private func notesWereNotSent(_ ids: [String]) {
        let back = Set(ids)
        for workspace in workspaces where workspace.review.contains(where: { back.contains($0.id) }) {
            update(workspace: workspace.id) { workspace in
                for index in workspace.review.indices where back.contains(workspace.review[index].id) { workspace.review[index].sent = nil }
            }
        }
        scheduleSave()
        reviewDidChange()
    }

    /// Into the input, unsent, the same as a quote: there may be something to add before pressing Return.
    private func deliverReview(to terminal: TerminalController) {
        guard let message = notesMessage(for: terminal) else { return }
        focusAgent(terminal)
        terminal.send(text: AgentReference.bracketedPaste(message.parts.text))
        notesWereSent(message.ids)
        let count = message.ids.count
        let title = count == 1 ? String(localized: "1 note sent") : String(localized: "\(count) notes sent")
        showToast(title: title, detail: String(localized: "Press Return in the session when you're ready."),
                  symbol: "paperplane", tint: .accentColor, actionTitle: String(localized: "Bring Back")) { [weak self] in
            self?.notesWereNotSent(message.ids)
        }
    }

    /// An agent moved some lines: the list says where they are now. A sent note whose lines are gone was acted on.
    func refreshReviewLines(in id: WorkspaceID? = nil) {
        let workspace = id ?? activeID
        let comments = (workspaces.first { $0.id == workspace }?.review ?? []).filter { $0.excerpt != nil && $0.commit == nil }
        guard !comments.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var moved: [String: ClosedRange<Int>] = [:]
            var gone: Set<String> = []
            var there: Set<String> = []
            for comment in comments {
                guard let text = try? String(contentsOfFile: comment.path, encoding: .utf8) else { continue }
                switch ReviewLocator.place(of: comment, in: text) {
                case .lines(let range):
                    there.insert(comment.id)
                    if range.lowerBound != comment.firstLine { moved[comment.id] = range }
                case .gone:
                    if comment.sent != nil { gone.insert(comment.id) }
                case .wholeFile:
                    break
                }
            }
            let changedNow = gone, stillThere = there, movedNow = moved
            await MainActor.run {
                guard let self else { return }
                let before = NoteWriting.shared.changed
                let after = before.subtracting(stillThere).union(changedNow)
                if after != before { NoteWriting.shared.changed = after }
                guard !movedNow.isEmpty || after != before else { return }
                if !movedNow.isEmpty {
                    self.update(workspace: workspace) { workspace in
                        for index in workspace.review.indices {
                            guard let range = movedNow[workspace.review[index].id] else { continue }
                            workspace.review[index].firstLine = range.lowerBound
                            workspace.review[index].lastLine = range.upperBound
                        }
                    }
                    self.scheduleSave()
                }
                self.reviewDidChange()
            }
        }
    }

    /// Every open viewer of a file with notes redraws its marks, and the box opens or closes where it is.
    func reviewDidChange() {
        for workspace in workspaces {
            for item in workspace.items + (workspace.peek.map { [$0] } ?? []) {
                existingController(for: item.id)?.reviewChanged()
                NoteLayer.existing(for: item.id)?.refresh()
            }
        }
    }

    func reviewMarkers(for path: String, text: String) -> [Int: [ReviewComment]] {
        var markers: [Int: [ReviewComment]] = [:]
        for comment in reviewComments(on: path) where comment.spot == nil && comment.commit == nil {
            if case .lines(let range) = ReviewLocator.place(of: comment, in: text) {
                markers[range.lowerBound, default: []].append(comment)
            }
        }
        return markers
    }

    /// Each note on lines of this file, with the lines it's on now.
    func notedLines(for path: String, text: String) -> [(comment: ReviewComment, lines: ClosedRange<Int>)] {
        reviewComments(on: path).compactMap { comment in
            guard comment.spot == nil, comment.commit == nil, comment.firstLine != nil,
                  case .lines(let range) = ReviewLocator.place(of: comment, in: text) else { return nil }
            return (comment, range)
        }
    }

    /// A diff's rows are found by their line in the file, or for removed rows, by their own text.
    /// A note on one commit's diff stays there, since another's line 12 is a different line.
    func reviewMarkers(for path: String, rows: [DiffLine], commit: String?) -> [Int: [ReviewComment]] {
        var markers: [Int: [ReviewComment]] = [:]
        for comment in reviewComments(on: path) where comment.commit == commit && comment.spot == nil {
            let row: Int?
            if let first = comment.firstLine {
                row = rows.firstIndex { $0.newLine == first }
            } else if comment.quoteIsDiff, let quote = comment.quote, let line = quote.split(separator: "\n").first {
                let text = line.dropFirst()
                row = rows.firstIndex { $0.kind == .removed && $0.text == text }
            } else {
                row = nil
            }
            if let row { markers[row, default: []].append(comment) }
        }
        return markers
    }

    /// Notes can be in another workspace's list only if that file is open there too.
    func reviewComments(on path: String) -> [ReviewComment] {
        workspaces.flatMap { $0.reviewComments(on: path) }
    }

    func openReviewComment(_ comment: ReviewComment) {
        // A sent note whose lines changed: what the agent did there is the thing to look at.
        if comment.sent != nil, NoteWriting.shared.changed.contains(comment.id), hasChanges(comment.path) {
            peekDiff(DiffSpec(path: comment.path), takeFocus: true)
            return
        }
        if let address = comment.spot?.address {
            for item in active.items {
                if let web = existingController(for: item.id) as? WebController, web.currentURLString == address {
                    _ = focusItem(item.id)
                    return
                }
            }
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
            return
        }
        let line = (try? String(contentsOfFile: comment.path, encoding: .utf8)).flatMap { text -> Int? in
            if case .lines(let range) = ReviewLocator.place(of: comment, in: text) { return range.lowerBound }
            return nil
        }
        if let commit = comment.commit {
            peekDiff(DiffSpec(path: comment.path, commit: commit), takeFocus: true)
            return
        }
        if comment.quoteIsDiff, hasChanges(comment.path) {
            peekDiff(DiffSpec(path: comment.path), takeFocus: true)
            return
        }
        open(path: comment.path, line: line, intent: .peek(takeFocus: true))
    }
}

/// Lines of a file, for what a comment is on.
enum ReviewQuote {
    nonisolated static func lines(_ first: Int, _ last: Int, of path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let all = text.components(separatedBy: "\n")
        guard first >= 1, first <= all.count else { return nil }
        return all[(first - 1)..<min(max(last, first), all.count)].joined(separator: "\n")
    }

    /// A quotation made for ⌘L says where it's from in its first line. A comment's list says that already.
    nonisolated static func body(_ quote: String) -> String {
        quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The sidebar section

struct ReviewHeaderActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        let waiting = here.active.pendingNotes.count
        let sent = here.active.review.count - waiting
        if waiting > 0 {
            Text("\(waiting)")
                .foregroundStyle(.faint)
                .font(.caption)
            Button {
                model.sendReview()
            } label: {
                Image(systemName: "paperplane")
            }
            .help("Send to Agent (\(model.shortcutSymbol(for: "sendReview") ?? "⌥⇧⌘L"))")
            .accessibilityLabel("Send Notes to Agent")
        }
        Menu {
            if sent > 0 { Button("Clear Sent Notes") { model.clearSentNotes() } }
            Button("Discard All Notes") { model.discardReview() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

struct ReviewList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowScope) private var scope
    /// This window's workspace, which may not be the one in front.
    private var here: WindowModel { WindowModel(app: model, scope: scope) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                // What's waiting first, in the order of its numbers.
                ForEach(here.active.pendingNotes + here.active.review.filter { $0.sent != nil }) { comment in
                    ReviewRow(comment: comment, number: here.active.noteNumber(comment.id))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}

struct ReviewRow: View {
    let comment: ReviewComment
    let number: Int?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var location: String {
        let name = (comment.path as NSString).lastPathComponent
        if let spot = comment.spot { return (spot.address.flatMap { URL(string: $0)?.host } ?? name) + ", " + spot.label }
        guard let first = comment.firstLine else { return name }
        return "\(name):\(first)"
    }

    private var changed: Bool { comment.sent != nil && NoteWriting.shared.changed.contains(comment.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            NotePinView(number: number, changed: changed)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(comment.text.isEmpty ? location : comment.summary)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(changed ? String(localized: "\(location), changed since") : location)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(comment.sent == nil ? 1 : 0.6)
            Spacer(minLength: 0)
            if hovering {
                Button {
                    model.removeReviewComment(comment.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove Note")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openReviewComment(comment) }
        .accessibleRow(comment.summary, value: location) { model.openReviewComment(comment) }
        .accessibilityAction(named: "Remove Note") { model.removeReviewComment(comment.id) }
        .help(comment.text)
        .contextMenu {
            Button("Go to Note") { model.openReviewComment(comment) }
            Button("Remove Note") { model.removeReviewComment(comment.id) }
        }
    }
}
