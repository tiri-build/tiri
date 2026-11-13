import AppKit
import SwiftUI
import TiriCore

/// Writing to an agent in a box of its own, where a prompt of the agent's can't take the keys: it sits at the
/// foot of the agent's terminal, where its input is, no taller than what's been written. It's a real text
/// view, so input methods and dictation work, Return is a new line, a paste shows all of itself, and a
/// picture shows as the picture. ⌘↩ sends, and Esc keeps it for later.
@MainActor @Observable final class ComposeDrafts {
    static let shared = ComposeDrafts()
    /// What's written so far, by the terminal it's for.
    var words: [ItemID: String] = [:]
    /// Pictures and files going with it.
    var attached: [ItemID: [String]] = [:]
    /// Long text pasted in, each kept whole and shown small, as a picture is.
    var pasted: [ItemID: [String]] = [:]
    /// Terminals whose next message leaves the waiting notes behind.
    var withoutNotes: Set<ItemID> = []
    /// Why it wasn't sent, said in the box itself.
    var held: [ItemID: String] = [:]
    /// Counts up to hand the box the keyboard.
    var focusRequests = 0
    /// How many times the box has been opened. After a few, nothing needs to point at it any more.
    var opens = UserDefaults.standard.integer(forKey: "composeOpens") { didSet { UserDefaults.standard.set(opens, forKey: "composeOpens") } }
    static let opensToKnowIt = 3
    /// The attached file being looked at, if one is.
    var lookingAt: String?
    /// What `lookingAt` holds while the waiting notes are listed above the box. No file has this path.
    static let notesListed = "\u{0}notes"
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension AppModel {
    /// Whether to show, at the foot of this terminal, that there's a box for writing to what's in it: an agent is
    /// there, it isn't asking anything, and the box isn't something this person already knows.
    func invitesWriting(_ terminal: ItemID) -> Bool {
        guard ComposeDrafts.shared.opens < ComposeDrafts.opensToKnowIt, composingFor != terminal, !composerYields(terminal),
              let item = anyItem(terminal), case .terminal(let spec) = item.content else { return false }
        let program = spec.command?.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
        if let program, AgentCatalog.profile(executable: program) != nil { return true }
        // One started by hand in a shell, once it has taken a prompt.
        return runtimes[terminal]?.prompt != nil
    }

    /// A click on that: the box, for that terminal.
    func acceptWritingInvitation(_ terminal: ItemID) {
        focusItem(terminal)
        composeToAgent()
    }

    /// Its ×: not shown again.
    func declineWritingInvitation() { ComposeDrafts.shared.opens = ComposeDrafts.opensToKnowIt }

    private var draftRoot: String {
        (RemoteMirror.root as NSString).deletingLastPathComponent + "/Drafts"
    }

    private func draftPath(for terminal: ItemID) -> String { draftRoot + "/" + terminal + ".md" }
    private func pastesPath(for terminal: ItemID) -> String { draftRoot + "/" + terminal + ".pasted.json" }

    /// More than a few lines, or about a paragraph: shown small, so the box stays the size of what you typed.
    static func isLongPaste(_ text: String) -> Bool {
        text.count > 400 || text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > 4
    }

    func pasteIntoDraft(_ text: String, for terminal: ItemID) {
        ComposeDrafts.shared.pasted[terminal, default: []].append(text)
        ComposeDrafts.shared.held[terminal] = nil
        savePastes(terminal)
    }

    func removePaste(at index: Int, for terminal: ItemID) {
        guard ComposeDrafts.shared.pasted[terminal]?.indices.contains(index) == true else { return }
        ComposeDrafts.shared.pasted[terminal]?.remove(at: index)
        savePastes(terminal)
    }

    /// Into the words after all, to change it.
    func unfoldPaste(at index: Int, for terminal: ItemID) {
        guard let text = ComposeDrafts.shared.pasted[terminal]?[safe: index] else { return }
        removePaste(at: index, for: terminal)
        let words = ComposeDrafts.shared.words[terminal] ?? ""
        draftChanged(terminal, to: words.isEmpty ? text : words + "\n" + text)
        ComposeDrafts.shared.focusRequests += 1
    }

    private func savePastes(_ terminal: ItemID) {
        let list = ComposeDrafts.shared.pasted[terminal] ?? []
        let path = pastesPath(for: terminal)
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        try? FileManager.default.createDirectory(atPath: draftRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// What the box calls who it's to: the agent by name, or the program in that terminal.
    func composeRecipient(_ terminal: ItemID) -> String {
        guard let item = anyItem(terminal), case .terminal(let spec) = item.content else { return String(localized: "this terminal") }
        let program = spec.command?.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }
        if let program, let profile = AgentCatalog.profile(executable: program) { return profile.title }
        return program ?? String(localized: "this terminal")
    }

    var composerHasKeyboard: Bool { (NSApp.keyWindow ?? window)?.firstResponder is ComposerTextView }

    /// An input method is partway through a word in the box: Esc and Return are its own just now.
    var composerIsMidWord: Bool { ((NSApp.keyWindow ?? window)?.firstResponder as? ComposerTextView)?.hasMarkedText() == true }

    /// The agent is asking something, so the box steps aside and what it asked can be seen and answered.
    func composerYields(_ terminal: ItemID) -> Bool { runtimes[terminal]?.status == .needsInput }

    /// For ⌘↩, which a terminal otherwise keeps: in a terminal with nothing floating over it, or in the box.
    var canComposeHere: Bool {
        if composingFor != nil, composerHasKeyboard { return true }
        guard (NSApp.keyWindow ?? window)?.firstResponder is TiriTerminalView else { return false }
        if windowOfItsOwn != nil { return true }
        return active.peek == nil && frontTerminalItem != nil
    }

    /// The terminal the keys are in when it's in a window of its own.
    private var windowOfItsOwn: ItemID? {
        guard let key = NSApp.keyWindow, let id = detachedItem(of: key), let item = anyItem(id), case .terminal = item.content else { return nil }
        return id
    }

    private var frontTerminalItem: ItemID? {
        if let own = windowOfItsOwn { return own }
        guard let id = active.focused.active, let item = active.item(id), case .terminal = item.content else { return nil }
        return id
    }

    /// ⌘↩: opens the box for the terminal in front, goes back to it if it's open, and sends from inside it.
    func composeToAgent() {
        if let terminal = composingFor, anyItem(terminal) != nil, terminal == frontTerminalItem || composerHasKeyboard {
            if composerHasKeyboard { sendDraft(terminal) } else { ComposeDrafts.shared.focusRequests += 1 }
            return
        }
        guard let terminal = frontTerminalItem else {
            showToast(title: String(localized: "Go to a terminal first, then write to what's in it"), detail: nil, symbol: "square.and.pencil", tint: .secondary)
            return
        }
        if ComposeDrafts.shared.words[terminal] == nil {
            ComposeDrafts.shared.words[terminal] = (try? String(contentsOfFile: draftPath(for: terminal), encoding: .utf8)) ?? ""
            ComposeDrafts.shared.pasted[terminal] = (try? Data(contentsOf: URL(fileURLWithPath: pastesPath(for: terminal))))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        }
        ComposeDrafts.shared.opens += 1
        ComposeDrafts.shared.held[terminal] = nil
        composingFor = terminal
        ComposeDrafts.shared.focusRequests += 1
    }

    /// Kept as it's typed, so it's there after a restart. Nothing written keeps nothing.
    func draftChanged(_ terminal: ItemID, to words: String) {
        ComposeDrafts.shared.words[terminal] = words
        ComposeDrafts.shared.held[terminal] = nil
        let path = draftPath(for: terminal)
        if words.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        // A draft can hold anything meant for an agent, so it's as private as a conversation.
        try? FileManager.default.createDirectory(atPath: draftRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: path, contents: Data(words.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Esc: the box goes, what's in it stays, and the keys are the terminal's again.
    func closeComposer() {
        guard let terminal = composingFor else { return }
        // Esc with a picture up puts the picture away first.
        if ComposeDrafts.shared.lookingAt != nil {
            ComposeDrafts.shared.lookingAt = nil
            return
        }
        composingFor = nil
        guard anyItem(terminal) != nil else { return }
        if detachedItems.contains(terminal) { existingController(for: terminal)?.focus() } else { focusItem(terminal) }
    }

    func attachToDraft(_ paths: [String], for terminal: ItemID) {
        var list = ComposeDrafts.shared.attached[terminal] ?? []
        for path in paths where !list.contains(path) { list.append(path) }
        ComposeDrafts.shared.attached[terminal] = list
        ComposeDrafts.shared.held[terminal] = nil
    }

    func removeFromDraft(_ path: String, for terminal: ItemID) {
        ComposeDrafts.shared.attached[terminal]?.removeAll { $0 == path }
    }

    /// The paperclip: files or pictures to go with what's written.
    func chooseFilesForDraft(_ terminal: ItemID) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                self?.attachToDraft(panel.urls.map(\.path), for: terminal)
                ComposeDrafts.shared.focusRequests += 1
            }
        }
    }

    /// What's attached, then the words, then Return, into the terminal it's for. While the agent there is
    /// asking something nothing is sent, because the Return would answer that instead.
    func sendDraft(_ terminal: ItemID) {
        let words = (ComposeDrafts.shared.words[terminal] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = ComposeDrafts.shared.attached[terminal] ?? []
        let pasted = ComposeDrafts.shared.pasted[terminal] ?? []
        guard let target = existingController(for: terminal) as? TerminalController else { return }
        // Notes waiting in this workspace go with the message, under the words, unless they were left out.
        let notes = ComposeDrafts.shared.withoutNotes.contains(terminal) ? nil : notesMessage(for: target)
        guard !words.isEmpty || !attached.isEmpty || !pasted.isEmpty || notes != nil else { return }
        if runtimes[terminal]?.status == .needsInput {
            ComposeDrafts.shared.held[terminal] = String(localized: "\(composeRecipient(terminal)) is asking something first")
            return
        }
        // The way the paperclip adds them: a picture as a paste, another file as a mention, named as the server names it.
        // The words follow the files, which for a server may first have to be sent over.
        let rest = {
            // Each long paste as a paste of its own, which is how an agent folds it up on its side too.
            for text in pasted { target.send(text: AgentReference.bracketedPaste(text) + " ") }
            let written = [words, notes?.parts.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !written.isEmpty { target.send(text: AgentReference.bracketedPaste(written)) }
            // A moment for the agent to take the paste in, or the Return reads as part of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { target.send(text: "\r") }
        }
        // A note's picture goes the way an attached picture does, so it reaches an agent on a server too.
        let files = attached + (notes?.parts.pictures ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        if files.isEmpty {
            rest()
        } else if let agent = target.runningAgent {
            insert(files, into: target, agent: agent, then: rest)
        } else {
            if !attached.isEmpty { target.send(text: ShellQuote.join(attached) + " ") }
            rest()
        }
        if let notes { notesWereSent(notes.ids) }
        ComposeDrafts.shared.withoutNotes.remove(terminal)
        ComposeDrafts.shared.attached[terminal] = nil
        ComposeDrafts.shared.pasted[terminal] = nil
        ComposeDrafts.shared.lookingAt = nil
        savePastes(terminal)
        draftChanged(terminal, to: "")
        closeComposer()
    }

    /// The box has stepped aside for the agent's question, so the keys go where the answer is typed.
    func giveKeyboardToTerminal(_ terminal: ItemID) {
        guard composerHasKeyboard || (NSApp.keyWindow ?? window)?.firstResponder == nil else { return }
        controller(for: terminal)?.focus()
    }

    /// A press on something attached shows it above the box, and a second press puts it away.
    func lookAtAttached(_ path: String) {
        ComposeDrafts.shared.lookingAt = ComposeDrafts.shared.lookingAt == path ? nil : path
    }

    /// The first lines of a file that's text, for a look at it. Nothing for one that isn't, or a folder.
    static func startOfFile(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty, !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", maxSplits: 14, omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
    }

    /// Files and pictures dropped on the box.
    func takeDrop(_ providers: [NSItemProvider], for terminal: ItemID) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in AppModel.shared.attachToDraft([url.path], for: terminal) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in
                        if let saved = AppModel.shared.savePastedImage(image) { AppModel.shared.attachToDraft([saved], for: terminal) }
                    }
                }
            }
        }
    }

    /// From a paste into the box: pictures and files on the clipboard, to go with it instead of into its words.
    func attachmentsOnPasteboard(_ board: NSPasteboard) -> [String] {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return pasteableImagePaths(urls.map(\.path), from: board) }
        // A picture, as a screenshot is. Copied from a web page it comes with its address as words: still the picture.
        let words = board.string(forType: .string) ?? ""
        let isAddress = !words.contains(where: \.isNewline) && (words.hasPrefix("http://") || words.hasPrefix("https://") || words.hasPrefix("file://"))
        let hasPicture = board.availableType(from: [.png, .tiff]) != nil
        if hasPicture, words.isEmpty || isAddress, let image = NSImage(pasteboard: board), let saved = savePastedImage(image) { return [saved] }
        return []
    }
}

/// The box itself, at the foot of the terminal it's for.
struct AgentComposer: View {
    let terminal: ItemID
    @Environment(AppModel.self) private var model
    @State private var textHeight: CGFloat = 18

    private var drafts: ComposeDrafts { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// With the size chosen for terminals and files, so one zoom covers what you read and what you write.
    private var size: CGFloat { CGFloat(model.settings.codeFontSizeZoomed) + 0.5 }

    var body: some View {
        if model.composerYields(terminal) {
            stoodAside
        } else {
            VStack(spacing: 8) {
                if drafts.lookingAt == ComposeDrafts.notesListed, model.notesWaiting(for: terminal) > 0 {
                    NotesListed(terminal: terminal)
                } else if let path = drafts.lookingAt, (drafts.attached[terminal] ?? []).contains(path) {
                    looking(at: path)
                }
                box
            }
            .animation(.easeOut(duration: 0.14), value: drafts.lookingAt)
        }
    }

    /// What's attached, large enough to check it's the right one. A click or Esc puts it away.
    private func looking(at path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        return Button {
            drafts.lookingAt = nil
        } label: {
            Group {
                if AgentReference.isImage(path: path), let picture = NSImage(contentsOfFile: path) {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(picture.size.width, 688), maxHeight: min(picture.size.height, 380))
                } else {
                    // Another file: where it is and how it starts, which is enough to know it's the right one.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let start = AppModel.startOfFile(path) {
                            Text(verbatim: start)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: 688, alignment: .leading)
                }
            }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .help("Click to put it away")
        .accessibilityLabel(Text(verbatim: name))
        .transition(.opacity)
    }

    /// While the agent asks: out of the way of its question, saying the message is safe.
    private var stoodAside: some View {
        Label("Your message is kept. Answer \(model.composeRecipient(terminal)) first.", systemImage: "square.and.pencil")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { model.giveKeyboardToTerminal(terminal) }
            .transition(.opacity)
    }

    @ViewBuilder private var box: some View {
        let words = drafts.words[terminal] ?? ""
        let attached = drafts.attached[terminal] ?? []
        let pasted = drafts.pasted[terminal] ?? []
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            if !attached.isEmpty || !pasted.isEmpty || model.notesWaiting(for: terminal) > 0 { attachments(attached, pasted: pasted) }
            ZStack(alignment: .topLeading) {
                if words.isEmpty {
                    Text("Write to \(model.composeRecipient(terminal))")
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerText(words: words, height: $textHeight, focusRequests: drafts.focusRequests, size: size,
                             onChange: { model.draftChanged(terminal, to: $0) },
                             onSend: { model.sendDraft(terminal) },
                             onClose: { model.closeComposer() },
                             onPaste: { paths in model.attachToDraft(paths, for: terminal) },
                             onLongPaste: { text in model.pasteIntoDraft(text, for: terminal) })
                    // No taller than what's written, up to about ten lines, then it scrolls.
                    .frame(height: min(max(textHeight, 18), 190))
                    .accessibilityLabel(Text("Message to \(model.composeRecipient(terminal))"))
            }
            HStack(spacing: 10) {
                Button {
                    model.chooseFilesForDraft(terminal)
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add files or pictures")
                .accessibilityLabel("Add files or pictures")
                if let held = drafts.held[terminal] {
                    Label(held, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    model.sendDraft(terminal)
                } label: {
                    HStack(spacing: 6) {
                        Label("Send", systemImage: "paperplane.fill")
                        Text(verbatim: "⌘↩").font(.system(size: 10.5)).opacity(0.75)
                    }
                }
                .tiriGlassButton(prominent: true)
                .controlSize(.small)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty && pasted.isEmpty
                          && (model.notesWaiting(for: terminal) == 0 || drafts.withoutNotes.contains(terminal)))
                .help("Send (⌘↩)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 720)
        // Opaque, so the words are read against the box and not against the terminal behind.
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        // Dropped anywhere on the box, files and pictures go along with the message.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            model.takeDrop(providers, for: terminal)
            return true
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
    }

    private func attachments(_ paths: [String], pasted: [String]) -> some View {
        // On to a second line when there are many, so none is out of sight.
        WrappingRow(spacing: 8) {
            Group {
                if model.notesWaiting(for: terminal) > 0 { NotesChip(terminal: terminal) }
                ForEach(Array(pasted.enumerated()), id: \.offset) { index, text in
                    PastedTextChip(text: text, remove: { model.removePaste(at: index, for: terminal) },
                                   unfold: { model.unfoldPaste(at: index, for: terminal) })
                }
                ForEach(paths, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        AttachedFileTile(path: path)
                        Button {
                            model.removeFromDraft(path, for: terminal)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .help("Take this out")
                        .accessibilityLabel(Text("Remove \((path as NSString).lastPathComponent)"))
                    }
                    .help((path as NSString).lastPathComponent)
                }
            }
        }
    }
}

/// At the foot of a terminal with an agent in it, until the box is known: that you can write to it here, and the key.
struct WritingInvitation: View {
    let terminal: ItemID
    @Environment(AppModel.self) private var model
    @State private var over = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.acceptWritingInvitation(terminal)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                    Text("Write to \(model.composeRecipient(terminal))").font(.system(size: 11.5))
                    Text(verbatim: "⌘↩").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 10)
                .padding(.trailing, over ? 4 : 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a box for a longer message, pictures and files (⌘↩)")
            if over {
                Button {
                    model.declineWritingInvitation()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
                .help("Don't show this")
                .accessibilityLabel("Don't show this")
            }
        }
        .foregroundStyle(.secondary)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .onHover { over = $0 }
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .transition(.opacity)
    }
}

/// Side by side, going on to a new line when the box is full.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    private func place(_ subviews: Subviews, in width: CGFloat) -> (spots: [CGPoint], size: CGSize) {
        var spots: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            spots.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (spots, CGSize(width: widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, spot) in zip(subviews, place(subviews, in: bounds.width).spots) {
            view.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), proposal: .unspecified)
        }
    }
}

/// A picture or file going with the message. A click shows it above the box.
private struct AttachedFileTile: View {
    let path: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let picture = AgentReference.isImage(path: path) ? NSImage(contentsOfFile: path) : nil
        Button {
            model.lookAtAttached(path)
        } label: {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "doc").font(.system(size: 15))
                        Text(verbatim: (path as NSString).lastPathComponent).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                    .padding(4)
                }
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: (path as NSString).lastPathComponent))
        .overlay {
            if ComposeDrafts.shared.lookingAt == path {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

/// A long paste, small: how much there is and how it starts. A click shows all of it.
private struct PastedTextChip: View {
    let text: String
    let remove: () -> Void
    let unfold: () -> Void
    @State private var showing = false

    private var size: String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return lines > 1 ? String(localized: "\(lines) lines") : String(localized: "\(text.count) characters")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { showing = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(size, systemImage: "text.alignleft")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(verbatim: text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 150, height: 48, alignment: .topLeading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See what you pasted")
            .accessibilityLabel(Text("Pasted text, \(size)"))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Take this out")
            .accessibilityLabel("Remove pasted text")
        }
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .trailing, spacing: 10) {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 460, height: 260)
                Button("Put in Message") {
                    showing = false
                    unfold()
                }
                .controlSize(.small)
                .help("Move it into what you're writing, to change it")
            }
            .padding(14)
        }
    }
}

/// The text view in the box. AppKit's own, for input methods, dictation, undo and spelling.
final class ComposerTextView: NSTextView {
    /// Asked for the keyboard before it was in a window, it takes it on arriving.
    var wantsKeyboard = false

    func takeKeyboard() {
        guard wantsKeyboard, let window else { return }
        if window.makeFirstResponder(self) { wantsKeyboard = false }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }

    var onSend: (() -> Void)?
    var onClose: (() -> Void)?
    var onPaste: (([String]) -> Void)?
    var onLongPaste: ((String) -> Void)?

    /// A plain text view says it can't take a picture, and Paste goes grey with one on the clipboard.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), FileTreeController.pasteboard.availableType(from: [.png, .tiff, .fileURL, .string]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), FileTreeController.pasteboard.availableType(from: [.png, .tiff, .fileURL, .string]) != nil { return true }
        return super.validateMenuItem(item)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↩, when nothing ahead of the view took it. A word an input method is partway through goes in first.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            if hasMarkedText() { unmarkText() }
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc in the middle of a word is the input method's, to drop its candidates.
        if hasMarkedText() {
            super.cancelOperation(sender)
            return
        }
        onClose?()
    }

    // A file or picture dragged onto the words goes along with them, where a text view would type its path.
    private func droppedFiles(_ sender: NSDraggingInfo) -> [String] {
        let board = sender.draggingPasteboard
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        if board.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: board), let saved = AppModel.shared.savePastedImage(image) { return [saved] }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onPaste?(files)
        return true
    }

    override func paste(_ sender: Any?) {
        // A picture or a file goes along with the message, shown as itself.
        let attached = AppModel.shared.attachmentsOnPasteboard(FileTreeController.pasteboard)
        if !attached.isEmpty {
            onPaste?(attached)
            return
        }
        // A long paste goes along whole and shows small, so the box stays the size of what's typed.
        if let text = FileTreeController.pasteboard.string(forType: .string), AppModel.isLongPaste(text) {
            onLongPaste?(text)
            return
        }
        pasteAsPlainText(sender)
    }
}

private struct ComposerText: NSViewRepresentable {
    let words: String
    @Binding var height: CGFloat
    let focusRequests: Int
    let size: CGFloat
    let onChange: (String) -> Void
    let onSend: () -> Void
    let onClose: () -> Void
    let onPaste: ([String]) -> Void
    let onLongPaste: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerText
        var answered = -1
        init(_ parent: ComposerText) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
            measure(view)
        }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let wanted = ceil(layout.usedRect(for: container).height)
            if abs(wanted - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = wanted }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: size)
        view.textColor = .labelColor
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.insertionPointColor = .controlAccentColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        // What's typed is what's sent: an agent takes straight quotes and two hyphens as they are.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.string = words
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.onSend = onSend
        view.onClose = onClose
        view.onPaste = onPaste
        view.onLongPaste = onLongPaste
        if view.font?.pointSize != size { view.font = .systemFont(ofSize: size) }
        if view.string != words, !view.hasMarkedText() { view.string = words }
        context.coordinator.measure(view)
        if context.coordinator.answered != focusRequests {
            context.coordinator.answered = focusRequests
            view.wantsKeyboard = true
            DispatchQueue.main.async { view.takeKeyboard() }
        }
    }
}
