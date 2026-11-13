import AppKit
import SwiftUI
import TiriCore

// MARK: - The mark

/// The mark of a note, the same wherever one is: beside a line, on a page, on a picture, in the list.
/// A waiting note shows its number, which is its number in the message too. A sent one is an outline.
enum NotePin {
    static let size = NSSize(width: 18, height: 16)

    /// A bubble with one square corner, which points at what the note is on.
    static func path(in rect: NSRect, flipped: Bool) -> NSBezierPath {
        let radius = rect.height / 2
        // The square corner is the bottom left as seen, whichever way the view counts.
        let top = flipped ? rect.minY : rect.maxY
        let bottom = flipped ? rect.maxY : rect.minY
        let down: CGFloat = flipped ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + radius, y: top))
        path.line(to: NSPoint(x: rect.maxX - radius, y: top))
        path.appendArc(from: NSPoint(x: rect.maxX, y: top), to: NSPoint(x: rect.maxX, y: top + down * radius), radius: radius)
        path.appendArc(from: NSPoint(x: rect.maxX, y: bottom), to: NSPoint(x: rect.maxX - radius, y: bottom), radius: radius)
        path.line(to: NSPoint(x: rect.minX, y: bottom))
        path.line(to: NSPoint(x: rect.minX, y: top + down * radius))
        path.appendArc(from: NSPoint(x: rect.minX, y: top), to: NSPoint(x: rect.minX + radius, y: top), radius: radius)
        path.close()
        return path
    }

    /// Draws one with its top left at `origin`, in a flipped view. Returns where it is, for clicks.
    @MainActor @discardableResult
    static func draw(_ comment: ReviewComment, at origin: NSPoint, flipped: Bool = true) -> NSRect {
        let number = AppModel.shared.noteNumber(comment.id)
        let changed = comment.sent != nil && NoteWriting.shared.changed.contains(comment.id)
        return draw(number: number, changed: changed, at: origin, flipped: flipped)
    }

    /// The + beside a line the pointer is on: a click notes that line, a drag from it notes several.
    @MainActor @discardableResult
    static func drawPlus(at origin: NSPoint) -> NSRect {
        let rect = NSRect(x: origin.x, y: origin.y, width: 16, height: 16)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSColor.white.setStroke()
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: rect.midX - 4, y: rect.midY))
        plus.line(to: NSPoint(x: rect.midX + 4, y: rect.midY))
        plus.move(to: NSPoint(x: rect.midX, y: rect.midY - 4))
        plus.line(to: NSPoint(x: rect.midX, y: rect.midY + 4))
        plus.lineWidth = 1.6
        plus.lineCapStyle = .round
        plus.stroke()
        return rect
    }

    @MainActor @discardableResult
    static func draw(number: Int?, changed: Bool, at origin: NSPoint, flipped: Bool = true) -> NSRect {
        let label = number.map(String.init) ?? (changed ? "✓" : "")
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let filled = number != nil
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: filled ? NSColor.white : NSColor.controlAccentColor]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let rect = NSRect(x: origin.x, y: origin.y, width: max(size.width, textSize.width + 10), height: size.height)
        let shape = path(in: filled ? rect : rect.insetBy(dx: 0.75, dy: 0.75), flipped: flipped)
        if filled {
            NSColor.controlAccentColor.setFill()
            shape.fill()
        } else {
            // Over code, a light page or a picture alike: a wash of its own color, which reads on any of them.
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            shape.fill()
            NSColor.controlAccentColor.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        return rect
    }
}

struct NotePinView: View {
    let number: Int?
    var changed = false

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 1.5, bottomTrailingRadius: 8, topTrailingRadius: 8, style: .continuous)
        Text(verbatim: number.map(String.init) ?? (changed ? "✓" : ""))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(number == nil ? Color.accentColor : Color.white)
            .frame(minWidth: 18, minHeight: 16)
            .background { if number != nil { shape.fill(Color.accentColor) } else { shape.strokeBorder(Color.accentColor, lineWidth: 1.5) } }
            .fixedSize()
            .accessibilityLabel(number.map { String(localized: "Note \($0)") } ?? String(localized: "Sent note"))
    }
}

// MARK: - Typing one

/// Return adds, ⇧↩ is a new line, ⌘↩ adds and sends, Esc closes. A word an input method is partway through gets its keys first.
final class NoteTextView: NSTextView {
    var onAdd: (() -> Void)?
    var onSend: (() -> Void)?
    var onClose: (() -> Void)?
    private var wantsKeyboard = true

    private func takeKeyboard() {
        guard wantsKeyboard, let window else { return }
        if window.makeFirstResponder(self) { wantsKeyboard = false }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        let held = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if held == .command {
            onSend?()
        } else if held.isEmpty {
            onAdd?()
        } else {
            insertNewlineIgnoringFieldEditor(nil)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            super.cancelOperation(sender)
            return
        }
        onClose?()
    }
}

private struct NoteText: NSViewRepresentable {
    @Binding var text: String
    let size: CGFloat
    let onAdd: () -> Void
    let onSend: () -> Void
    let onClose: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteText
        init(_ parent: NoteText) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NoteTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: size)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        // A note is about code, so the Mac mustn't rewrite what's typed.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.string = text
        view.setAccessibilityLabel(String(localized: "Note"))
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NoteTextView else { return }
        view.onAdd = onAdd
        view.onSend = onSend
        view.onClose = onClose
        if view.string != text, !view.hasMarkedText() { view.string = text }
    }
}

// MARK: - The box

/// Where a note is written. The same box under lines of code, beside an element of a page and beside a spot on a picture.
struct NoteBox: View {
    var floating = false
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 340
    static let height: CGFloat = 104

    private var writing: NoteWriting { .shared }

    var body: some View {
        @Bindable var writing = writing
        let open = writing.open
        let editing = open?.editing != nil
        let empty = writing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if writing.text.isEmpty {
                    Text("What about this?")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                NoteText(text: $writing.text, size: 13, onAdd: { model.commitNote() }, onSend: { model.commitNote(sending: true) },
                         onClose: { model.closeNote() })
            }
            .frame(height: 50)
            HStack(spacing: 8) {
                if editing {
                    // On the far side from Add, so a second click meant for Add can't land on it.
                    Button {
                        model.removeOpenNote()
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this note")
                    .accessibilityLabel("Remove Note")
                }
                Text(verbatim: open?.anchor.description ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button {
                    model.commitNote()
                } label: {
                    HStack(spacing: 5) {
                        Text(editing ? String(localized: "Save") : String(localized: "Add"))
                        Text(verbatim: "↩").font(.system(size: 10.5)).opacity(0.75)
                    }
                }
                .tiriGlassButton(prominent: true)
                .controlSize(.small)
                .disabled(empty)
                .help("Return adds it. ⌘↩ adds it and sends your notes to the agent.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: Self.width, height: Self.height)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(floating ? 0.3 : 0.14), radius: floating ? 16 : 6, y: floating ? 6 : 2)
        .accessibilityElement(children: .contain)
    }
}

/// A saved note, readable where it was made. A click opens it.
struct NoteCard: View {
    let comment: ReviewComment
    let item: ItemID
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    static let height: CGFloat = 26

    var body: some View {
        let changed = comment.sent != nil && NoteWriting.shared.changed.contains(comment.id)
        Button {
            model.editNote(comment, in: item, at: nil)
        } label: {
            HStack(spacing: 7) {
                NotePinView(number: model.noteNumber(comment.id), changed: changed)
                Text(verbatim: comment.summary)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(comment.sent == nil ? 1 : 0.6)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.height)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(comment.text)
    }
}

/// In the box for writing to an agent: the notes that will go with the message. A click lists them above the box,
/// to read and to delete. Its × leaves them out of this message, as any attachment's does, and puts them back.
struct NotesChip: View {
    let terminal: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = (model.workspace(containing: terminal) ?? model.active).pendingNotes
        let left = ComposeDrafts.shared.withoutNotes.contains(terminal)
        let listed = ComposeDrafts.shared.lookingAt == ComposeDrafts.notesListed
        ZStack(alignment: .topTrailing) {
            Button {
                ComposeDrafts.shared.lookingAt = listed ? nil : ComposeDrafts.notesListed
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        NotePinView(number: notes.count)
                        Text(notes.count == 1 ? String(localized: "note") : String(localized: "notes"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    Text(verbatim: left ? String(localized: "Left out") : (notes.first?.summary ?? ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 10)
                }
                .padding(.horizontal, 9)
                .frame(width: 150, height: 48, alignment: .leading)
                .background(Color.accentColor.opacity(left ? 0.04 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor.opacity(listed ? 1 : (left ? 0.15 : 0.4)), lineWidth: listed ? 2 : 1))
                .opacity(left ? 0.6 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See these notes")
            .accessibilityLabel(notes.count == 1 ? String(localized: "1 note goes with this message") : String(localized: "\(notes.count) notes go with this message"))
            Button {
                if left { ComposeDrafts.shared.withoutNotes.remove(terminal) } else { ComposeDrafts.shared.withoutNotes.insert(terminal) }
            } label: {
                Image(systemName: left ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill").font(.system(size: 13)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(2)
            .help(left ? String(localized: "Send them with this message") : String(localized: "Leave them out of this message"))
            .accessibilityLabel(left ? String(localized: "Send them with this message") : String(localized: "Leave them out of this message"))
        }
    }
}

/// Above the box: every waiting note in full, with what it's on, and a way to delete each.
struct NotesListed: View {
    let terminal: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace(containing: terminal) ?? model.active
        let notes = workspace.pendingNotes
        // As tall as its notes, and scrolling only once there are more than fit above the box.
        let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    if index > 0 { Divider().opacity(0.5) }
                    HStack(alignment: .top, spacing: 9) {
                        NotePinView(number: index + 1)
                        VStack(alignment: .leading, spacing: 3) {
                            // A note that only points has no words, and then where it points says it.
                            Text(verbatim: note.text.isEmpty ? note.anchor.description : note.text)
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            // Where it was made, and the way back there.
                            Button {
                                model.openReviewComment(note)
                            } label: {
                                HStack(spacing: 4) {
                                    if !note.text.isEmpty {
                                        Text(verbatim: note.anchor.description)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Image(systemName: "arrow.up.forward").font(.system(size: 8.5, weight: .semibold))
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to where this note was made")
                            .accessibilityLabel("Go to Note")
                        }
                        // What a pointed note points at, with the place marked.
                        if let picture = note.spot?.picture, let image = NSImage(contentsOfFile: picture) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
                                .accessibilityHidden(true)
                        }
                        Button {
                            model.removeReviewComment(note.id)
                            if notes.count == 1 { ComposeDrafts.shared.lookingAt = nil }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11.5)).frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete this note")
                        .accessibilityLabel(Text("Delete note \(index + 1)"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
        ScrollView { rows }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 688)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .transition(.opacity)
    }
}

/// What sits in the space under noted lines of a file: the notes that end there, and the box when one is being written there.
struct NoteStrip: View {
    let item: ItemID
    let comments: [ReviewComment]
    let showsBox: Bool

    static let spacing: CGFloat = 4
    static let top: CGFloat = 3
    static let bottom: CGFloat = 4

    static func height(cards: Int, box: Bool) -> CGFloat {
        let parts = cards + (box ? 1 : 0)
        guard parts > 0 else { return 0 }
        return top + bottom + CGFloat(cards) * NoteCard.height + (box ? NoteBox.height : 0) + CGFloat(parts - 1) * spacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(comments) { comment in
                NoteCard(comment: comment, item: item)
            }
            if showsBox { NoteBox() }
        }
        .padding(.top, Self.top)
        .padding(.bottom, Self.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
