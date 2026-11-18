import AppKit
import SwiftUI
import TiriCore

@Observable final class ConversationImportDraft {
    @ObservationIgnored weak var sheetWindow: NSWindow?
    var window: String?
    var markdown = ""
    var problem: String?
    var canSave: Bool { !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension AppModel {
    var importedConversations: [ConversationSummary] { ImportedConversations.load(root: conversationRoot) }

    func openConversationImport() {
        closePalette(restoreFocus: false)
        conversationImport.markdown = NSPasteboard.general.string(forType: .string) ?? ""
        conversationImport.problem = nil
        conversationImport.window = currentWindow
    }

    @discardableResult
    func saveConversationImport() -> ConversationSummary? {
        guard conversationImport.canSave else { return nil }
        do {
            let summary = try ImportedConversations.save(markdown: conversationImport.markdown, root: conversationRoot,
                                                        cwd: active.remote == nil ? active.folders.first : nil)
            conversationsLoaded = [summary] + (conversationsLoaded ?? [])
            conversationImport.window = nil
            conversationImport.markdown = ""
            Task { await showConversation(summary) }
            return summary
        } catch {
            conversationImport.problem = error.localizedDescription
            return nil
        }
    }

    /// The main-window screenshot cannot see an attached sheet. Used only by the test-copy command.
    func pictureConversationImport(at path: String) throws {
        guard AppModel.isTestCopy, conversationImport.window != nil,
              let sheet = conversationImport.sheetWindow, let view = sheet.contentView else { throw ControlHandler.ControlFailure("No import sheet is showing.") }
        let content = view.superview ?? view
        content.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw ControlHandler.ControlFailure("Couldn't draw the import sheet.") }
        content.cacheDisplay(in: content.bounds, to: image)
        let picture = NSImage(size: content.bounds.size)
        picture.lockFocus()
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            content.bounds.fill()
        }
        image.draw(in: content.bounds)
        picture.unlockFocus()
        guard let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw ControlHandler.ControlFailure("Couldn't draw the import sheet.") }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

struct ConversationImportSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var editing: Bool

    var body: some View {
        @Bindable var draft = model.conversationImport
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste Markdown…").font(.title2.bold())
            Text("Paste text copied from ChatGPT or another source. It will be saved as a new conversation.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft.markdown)
                .font(.system(size: 13, design: .monospaced))
                .focused($editing)
                .border(.secondary.opacity(0.25))
                .accessibilityLabel("Markdown text")
            HStack(alignment: .top) {
                Text("Automatic title:").foregroundStyle(.secondary)
                Text(draft.canSave ? ImportedConversations.title(for: draft.markdown) : "—")
                    .lineLimit(2).textSelection(.enabled)
            }
            if let problem = draft.problem { Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Paste from Clipboard") { draft.markdown = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
                Button("Cancel") { draft.window = nil }.keyboardShortcut(.cancelAction)
                Button("Import Conversation") { model.saveConversationImport() }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canSave)
            }
        }
        .padding(24)
        .frame(width: 580, height: 480)
        .background(WindowAccessor { model.conversationImport.sheetWindow = $0 })
        .onAppear { editing = true }
    }
}

extension View {
    func conversationImportSheet(model: AppModel, window: String) -> some View {
        let showing = model.conversationImport.window == window
        return sheet(isPresented: Binding(get: { showing }, set: { if !$0 { model.conversationImport.window = nil } })) {
            ConversationImportSheet().environment(model)
        }
    }
}
