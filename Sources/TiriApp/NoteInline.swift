import AppKit
import SwiftUI
import TiriCore

/// Notes between the lines of a file. Under the last line a note is on, the text opens a space, and the note
/// sits in it: readable where it was made, and written there too. Nothing is added to the text itself.
final class NoteInline {
    struct Strip {
        var line: Int
        var comments: [ReviewComment]
        var box: Bool
        /// The same strip keeps its view when lines above it come and go, so a note being typed isn't lost.
        var key: String { box ? "box" : (comments.first?.id ?? "") }
    }

    private weak var textView: CodeTextView?
    private let item: ItemID
    private let lines: () -> LineTable
    /// The space under each line that has one, by the line's number from 1.
    private(set) var gaps: [Int: CGFloat] = [:]
    private var hosts: [String: (line: Int, view: NSHostingView<AnyView>)] = [:]
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(textView: CodeTextView, item: ItemID, lines: @escaping () -> LineTable) {
        self.textView = textView
        self.item = item
        self.lines = lines
        textView.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func range(ofLine line: Int) -> NSRange? {
        guard let textView else { return nil }
        let table = lines()
        guard line >= 1, line <= table.count else { return nil }
        let start = table.starts[line - 1]
        let end = line < table.count ? table.starts[line] : textView.nsText.length
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// The space after the paragraph this character ends, if it ends one that has a note under it.
    func gap(afterCharacter index: Int) -> CGFloat {
        guard !gaps.isEmpty, let textView else { return 0 }
        let text = textView.nsText
        guard index < text.length, text.character(at: index) == 10 || index == text.length - 1 else { return 0 }
        return gaps[lines().line(containing: index) + 1] ?? 0
    }

    func gap(belowLine line: Int) -> CGFloat { gaps[line] ?? 0 }

    func apply(_ strips: [Strip]) {
        guard let textView, let layout = textView.layoutManager else { return }
        var wanted: [Int: CGFloat] = [:]
        for strip in strips { wanted[strip.line] = NoteStrip.height(cards: strip.comments.count, box: strip.box) }
        let changed = Set(wanted.keys).union(gaps.keys).filter { wanted[$0] != gaps[$0] }
        gaps = wanted
        for line in changed {
            if let range = range(ofLine: line) { layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil) }
        }
        let keys = Set(strips.map(\.key))
        for (key, host) in hosts where !keys.contains(key) {
            host.view.removeFromSuperview()
            hosts[key] = nil
        }
        for strip in strips {
            let root = AnyView(NoteStrip(item: item, comments: strip.comments, showsBox: strip.box).environment(AppModel.shared))
            if let host = hosts[strip.key] {
                host.view.rootView = root
                hosts[strip.key]?.line = strip.line
            } else {
                let view = NSHostingView(rootView: root)
                textView.addSubview(view)
                hosts[strip.key] = (strip.line, view)
            }
        }
        if !changed.isEmpty {
            textView.needsDisplay = true
            onChange?()
        }
        reposition()
    }

    private var repositioning = false

    /// Each strip goes into the space under its line, wherever that line is now.
    func reposition() {
        guard !repositioning, let textView, let layout = textView.layoutManager, !hosts.isEmpty else { return }
        // Asking where a line is can lay text out, which asks for this again.
        repositioning = true
        defer { repositioning = false }
        let length = textView.nsText.length
        let visible = textView.enclosingScrollView?.contentView.bounds.width ?? textView.bounds.width
        for (_, host) in hosts {
            guard let range = range(ofLine: host.line), let gap = gaps[host.line] else { continue }
            let last = max(NSMaxRange(range) - 1, range.location)
            guard last < length else { continue }
            layout.ensureLayout(forCharacterRange: range)
            let fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: last), effectiveRange: nil)
            let frame = NSRect(x: textView.textContainerOrigin.x + 2, y: fragment.maxY + textView.textContainerOrigin.y - gap,
                               width: max(visible - 20, 240), height: gap)
            if host.view.frame != frame { host.view.frame = frame }
        }
    }
}
