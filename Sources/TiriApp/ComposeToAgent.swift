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
    /// Why it wasn't sent, said in the box itself.
    var held: [ItemID: String] = [:]
    /// Counts up to hand the box the keyboard.
    var focusRequests = 0
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension AppModel {
    static let composeHintShown = "composeHintShown"

    /// Once, after you've written to an agent the old way while looking at it: that there's a box for that.
    func hintAtComposing(after item: ItemID) {
        guard !UserDefaults.standard.bool(forKey: Self.composeHintShown), !Self.isTestCopy, isLookingAt(item), composingFor == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.composeHintShown)
        showToast(title: String(localized: "⌘↩ opens a box for writing to \(composeRecipient(item))"),
                  detail: String(localized: "Paste pictures and long text, type in any language, and a prompt can't take your keys."),
                  symbol: "square.and.pencil", tint: .accentColor, actionTitle: String(localized: "Show Me"), duration: 12) { [weak self] in
            self?.composeToAgent()
        }
    }

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

    /// For ⌘↩, which a terminal otherwise keeps: in a terminal with nothing floating over it, or in the box.
    var canComposeHere: Bool {
        if composingFor != nil, composerHasKeyboard { return true }
        guard active.peek == nil, (NSApp.keyWindow ?? window)?.firstResponder is TiriTerminalView else { return false }
        return frontTerminalItem != nil
    }

    private var frontTerminalItem: ItemID? {
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
        UserDefaults.standard.set(true, forKey: Self.composeHintShown)
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
        composingFor = nil
        if anyItem(terminal) != nil { focusItem(terminal) }
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
        guard !words.isEmpty || !attached.isEmpty || !pasted.isEmpty else { return }
        guard let target = existingController(for: terminal) as? TerminalController else { return }
        if runtimes[terminal]?.status == .needsInput {
            ComposeDrafts.shared.held[terminal] = String(localized: "\(composeRecipient(terminal)) is asking something first")
            return
        }
        for file in attached {
            target.send(text: AgentReference.bracketedPaste(imageAgentsTake(file)) + " ")
        }
        // Each long paste as a paste of its own, which is how an agent folds it up on its side too.
        for text in pasted { target.send(text: AgentReference.bracketedPaste(text) + " ") }
        if !words.isEmpty { target.send(text: AgentReference.bracketedPaste(words)) }
        // A moment for the agent to take the paste in, or the Return reads as part of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { target.send(text: "\r") }
        ComposeDrafts.shared.attached[terminal] = nil
        ComposeDrafts.shared.pasted[terminal] = nil
        savePastes(terminal)
        draftChanged(terminal, to: "")
        closeComposer()
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

    var body: some View {
        let words = drafts.words[terminal] ?? ""
        let attached = drafts.attached[terminal] ?? []
        let pasted = drafts.pasted[terminal] ?? []
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            if !attached.isEmpty || !pasted.isEmpty { attachments(attached, pasted: pasted) }
            ZStack(alignment: .topLeading) {
                if words.isEmpty {
                    Text("Write to \(model.composeRecipient(terminal))")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerText(words: words, height: $textHeight, focusRequests: drafts.focusRequests,
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
                    Label("Send", systemImage: "paperplane.fill")
                }
                .tiriGlassButton(prominent: true)
                .controlSize(.small)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty && pasted.isEmpty)
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
    }

    private func attachments(_ paths: [String], pasted: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(pasted.enumerated()), id: \.offset) { index, text in
                    PastedTextChip(text: text, remove: { model.removePaste(at: index, for: terminal) },
                                   unfold: { model.unfoldPaste(at: index, for: terminal) })
                }
                ForEach(paths, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if AgentReference.isImage(path: path), let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFill()
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
        // ⌘↩, when nothing ahead of the view took it.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

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
        view.font = .systemFont(ofSize: 13.5)
        view.textColor = .labelColor
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
        if view.string != words, !view.hasMarkedText() { view.string = words }
        context.coordinator.measure(view)
        if context.coordinator.answered != focusRequests {
            context.coordinator.answered = focusRequests
            view.wantsKeyboard = true
            DispatchQueue.main.async { view.takeKeyboard() }
        }
    }
}
