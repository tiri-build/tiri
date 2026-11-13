import AppKit
import SwiftUI
import TiriCore

/// Something pointed at, before it's a note.
struct NoteTarget {
    var anchor: ReviewAnchor
    /// Where it is in the note layer. A spot has no size.
    var rect: NSRect
    /// A few words shown beside the outline while pointing.
    var label: String
}

/// A viewer whose notes are marked, and written, in a layer over it: a page, a picture, a PDF, a diff.
/// A file's own text needs none of this, since its notes sit between its lines.
protocol NoteSurface: ItemController {
    /// False where notes start from the gutter and the layer only holds the box.
    var canPoint: Bool { get }
    /// What a click at `start`, or a drag from it to `end`, would note. Both in the layer's coordinates.
    /// `depth` steps out from the innermost thing there, for viewers that have things inside things.
    func noteTarget(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void)
    /// Where each of these is now, in the layer's coordinates. Nil for one that can't be found, or isn't in sight.
    func noteRects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void)
    /// The click has happened: whatever takes time, like a picture of the thing, is made now.
    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void)
    /// The notes this viewer wants marked in the layer.
    func notesToMark() -> [ReviewComment]
    /// Brings what a note is on into sight.
    func revealNote(_ anchor: ReviewAnchor)
}

extension NoteSurface {
    var canPoint: Bool { true }
    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) { reply(target.anchor) }
    func notesToMark() -> [ReviewComment] { [] }
    func revealNote(_ anchor: ReviewAnchor) {}
}

extension ReviewComment {
    var anchor: ReviewAnchor {
        ReviewAnchor(path: path, firstLine: firstLine, lastLine: lastLine, excerpt: excerpt, quote: quote, quoteIsDiff: quoteIsDiff, commit: commit, spot: spot)
    }
}

/// Lies over a viewer. It draws the marks of notes on what's shown, the outline of what the pointer is on while
/// pointing, and holds the box a note is written in. Clicks pass through it except while pointing, so a page
/// never hears the click that picked one of its buttons.
final class NoteLayer: NSView {
    private static var layers: [ItemID: NoteLayer] = [:]
    private static var keyMonitor: Any?

    /// Its tab is gone.
    static func forget(_ item: ItemID) {
        layers.removeValue(forKey: item)?.removeFromSuperview()
    }

    static func existing(for item: ItemID) -> NoteLayer? {
        guard let layer = layers[item] else { return nil }
        if layer.surface == nil {
            layers[item] = nil
            layer.removeFromSuperview()
            return nil
        }
        return layer
    }

    static func layer(for item: ItemID, controller: ItemController) -> NoteLayer? {
        guard let surface = controller as? NoteSurface else { return nil }
        if let layer = layers[item], layer.surface === surface { return layer }
        layers[item]?.removeFromSuperview()
        let layer = NoteLayer(item: item, surface: surface)
        layers[item] = layer
        watchKeys()
        return layer
    }

    /// A rectangle in one of a viewer's views, as the layer over that viewer counts: from the top left.
    static func rect(_ rect: NSRect, of view: NSView, in root: NSView) -> NSRect {
        let inRoot = view.convert(rect, to: root)
        return root.isFlipped ? inRoot : NSRect(x: inRoot.minX, y: root.bounds.height - inRoot.maxY, width: inRoot.width, height: inRoot.height)
    }

    /// A point in the layer, in one of the viewer's views, in that view's own coordinates.
    static func point(_ point: NSPoint, in root: NSView, to view: NSView) -> NSPoint {
        let inRoot = root.isFlipped ? point : NSPoint(x: point.x, y: root.bounds.height - point.y)
        return view.convert(inRoot, from: root)
    }

    let itemID: ItemID
    private(set) weak var surface: NoteSurface?
    private var marks: [(comment: ReviewComment, rect: NSRect, pin: NSRect)] = []
    private var hover: NoteTarget?
    private var drag: (start: NSPoint, now: NSPoint)?
    private var depth = 0
    private var lastPoint: NSPoint?
    private var optionHeld = false
    private var boxHost: NSHostingView<AnyView>?
    private var openRect: NSRect?
    private var refreshes = 0
    private var hovers = 0
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(item: ItemID, surface: NoteSurface) {
        self.itemID = item
        self.surface = surface
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    var isPointing: Bool {
        guard surface?.canPoint == true else { return false }
        return NoteWriting.shared.pointing.contains(itemID) || optionHeld
    }

    private var hasOpenBox: Bool { NoteWriting.shared.open?.item == itemID && boxHost != nil }

    // MARK: Whose clicks

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let boxHost, boxHost.frame.contains(local) { return super.hitTest(point) }
        if marks.contains(where: { $0.pin.insetBy(dx: -3, dy: -3).contains(local) }) { return self }
        return isPointing ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isPointing { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
    }

    // MARK: Pointing

    /// ⌥ held and nothing else, with the pointer over this viewer.
    private func noteOption(_ flags: NSEvent.ModifierFlags, at point: NSPoint?) {
        let held = flags.intersection([.option, .command, .control, .shift]) == .option && point.map(bounds.contains) == true
        guard held != optionHeld else { return }
        optionHeld = held
        pointingChanged()
        if held, let point { hover(at: point) }
    }

    func pointingChanged() {
        if !isPointing {
            hover = nil
            drag = nil
            depth = 0
        } else if let lastPoint, window != nil {
            hover(at: lastPoint)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        noteOption(event.modifierFlags, at: point)
        guard isPointing else { return }
        NSCursor.crosshair.set()
        depth = 0
        hover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        lastPoint = nil
        if optionHeld {
            optionHeld = false
            pointingChanged()
        }
        if hover != nil {
            hover = nil
            needsDisplay = true
        }
    }

    private func hover(at point: NSPoint) {
        guard isPointing, drag == nil, let surface else { return }
        if let boxHost, boxHost.frame.contains(point) {
            if hover != nil {
                hover = nil
                needsDisplay = true
            }
            return
        }
        hovers += 1
        let asked = hovers
        surface.noteTarget(from: point, to: point, depth: depth) { [weak self] target in
            guard let self, asked == self.hovers, self.isPointing else { return }
            self.hover = target
            self.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mark = marks.first(where: { $0.pin.insetBy(dx: -3, dy: -3).contains(point) }) {
            AppModel.shared.editNote(mark.comment, in: itemID, at: mark.rect)
            return
        }
        guard isPointing else { return }
        drag = (point, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        drag?.now = convert(event.locationInWindow, from: nil)
        hover = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        point(from: drag.start, to: drag.now)
    }

    /// A click, or a drag when the two are apart: what's there becomes a note being written.
    func point(from start: NSPoint, to end: NSPoint) {
        guard let surface else { return }
        let moved = abs(end.x - start.x) > 4 || abs(end.y - start.y) > 4
        hovers += 1
        surface.noteTarget(from: start, to: moved ? end : start, depth: moved ? 0 : depth) { [weak self] target in
            guard let self, let target else {
                self?.needsDisplay = true
                return
            }
            self.hover = nil
            self.depth = 0
            // One press of the button is one thing pointed at: the page takes clicks again once it's picked.
            if NoteWriting.shared.pointing.remove(self.itemID) != nil { self.pointingChanged() }
            surface.finishNote(target) { anchor in
                AppModel.shared.beginNote(anchor, in: self.itemID, at: target.rect)
            }
        }
    }

    /// For a test copy, where nothing can hover: what the pointer resting here would show.
    func hoverForTest(at point: NSPoint, depth: Int = 0) {
        self.depth = depth
        lastPoint = point
        hover(at: point)
    }

    private static func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            nonisolated(unsafe) let event = event
            let taken = MainActor.assumeIsolated { () -> Bool in
                for layer in layers.values where layer.window === event.window && layer.window != nil {
                    if event.type == .flagsChanged {
                        layer.noteOption(event.modifierFlags, at: layer.lastPoint)
                    } else if layer.takeKey(event) {
                        return true
                    }
                }
                return false
            }
            return taken ? nil : event
        }
    }

    /// While pointing with no box open: ↑ steps out to what holds the thing, ↓ back in, Esc stops pointing.
    private func takeKey(_ event: NSEvent) -> Bool {
        guard isPointing, !hasOpenBox, lastPoint != nil || event.keyCode == 53 else { return false }
        guard event.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 53:
            guard NoteWriting.shared.pointing.contains(itemID) else { return false }
            AppModel.shared.togglePointing(itemID)
            return true
        case 126, 125:
            // With only ⌥ held, ⌥↑ and ⌥↓ belong to whatever has the keyboard, unless that's this viewer.
            if !NoteWriting.shared.pointing.contains(itemID) {
                guard let holder = superview, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: holder) else { return false }
            }
            depth = event.keyCode == 126 ? depth + 1 : max(depth - 1, 0)
        default:
            return false
        }
        if let lastPoint { hover(at: lastPoint) }
        return true
    }

    // MARK: Marks and the box

    /// The note someone just came back to: its place is outlined for a moment, so the eye finds it.
    private var lit: String?
    private var litWork: DispatchWorkItem?

    func light(_ commentID: String) {
        lit = commentID
        litWork?.cancel()
        // The page may still be scrolling to it.
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
        let work = DispatchWorkItem { [weak self] in
            self?.lit = nil
            self?.needsDisplay = true
        }
        litWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        refresh()
    }

    func rect(of commentID: String) -> NSRect? {
        marks.first { $0.comment.id == commentID }?.rect
    }

    private var watchedClips: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Whatever scrolls inside the viewer moves the things notes are on, so each scrolling view is listened to.
    /// A PDF makes its own scroll view late, so this looks again each time.
    private func watchScrolling(in view: NSView) {
        if let scroll = view as? NSScrollView {
            let clip = scroll.contentView
            if watchedClips[ObjectIdentifier(clip)] == nil {
                clip.postsBoundsChangedNotifications = true
                watchedClips[ObjectIdentifier(clip)] = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        for child in view.subviews where !(child is NoteLayer) { watchScrolling(in: child) }
    }

    isolated deinit {
        for observer in watchedClips.values { NotificationCenter.default.removeObserver(observer) }
    }

    /// Notes changed, or what's under them moved.
    func refresh() {
        guard let surface else { return }
        watchScrolling(in: surface.view)
        let comments = surface.notesToMark()
        let open = NoteWriting.shared.open.flatMap { $0.item == itemID && !surface.notesSitInText ? $0 : nil }
        var anchors = comments.map(\.anchor)
        if let open { anchors.append(open.anchor) }
        refreshes += 1
        let asked = refreshes
        guard !anchors.isEmpty else {
            marks = []
            openRect = nil
            layOutBox(open: nil)
            needsDisplay = true
            return
        }
        surface.noteRects(for: anchors) { [weak self] rects in
            guard let self, asked == self.refreshes else { return }
            var found: [(ReviewComment, NSRect, NSRect)] = []
            for (index, comment) in comments.enumerated() {
                // The one being rewritten shows its box instead.
                guard index < rects.count, let rect = rects[index], comment.id != open?.editing else { continue }
                guard rect.intersects(self.bounds.insetBy(dx: -40, dy: -40)) else { continue }
                found.append((comment, rect, self.pinRect(for: rect)))
            }
            self.marks = found
            if let open {
                self.openRect = (rects.count == anchors.count ? rects[anchors.count - 1] : nil) ?? open.rect
            } else {
                self.openRect = nil
            }
            self.layOutBox(open: open)
            self.needsDisplay = true
        }
    }

    /// At the thing's top right corner, a little outside it, so the mark covers as little of it as it can.
    private func pinRect(for rect: NSRect) -> NSRect {
        let size = NotePin.size
        var origin = rect.width < 1 && rect.height < 1 ? NSPoint(x: rect.minX + 7, y: rect.minY - size.height - 5)
                                                       : NSPoint(x: rect.maxX - 7, y: rect.minY - size.height + 5)
        origin.x = min(max(origin.x, 2), max(bounds.width - size.width - 8, 2))
        origin.y = min(max(origin.y, 2), max(bounds.height - size.height - 2, 2))
        return NSRect(origin: origin, size: NSSize(width: size.width + 6, height: size.height))
    }

    private func layOutBox(open: NoteWriting.Open?) {
        guard open != nil else {
            boxHost?.removeFromSuperview()
            boxHost = nil
            return
        }
        let host: NSHostingView<AnyView>
        if let boxHost {
            host = boxHost
        } else {
            host = NSHostingView(rootView: AnyView(NoteBox(floating: true).environment(AppModel.shared)))
            addSubview(host)
            boxHost = host
        }
        let size = NSSize(width: NoteBox.width, height: NoteBox.height)
        // With nowhere in particular to be, it sits at the top, in the middle.
        let target = openRect ?? NSRect(x: bounds.midX - size.width / 2, y: 4, width: size.width, height: 0)
        var origin = NSPoint(x: target.minX, y: target.maxY + 10)
        // Under the thing where there's room, over it where there isn't, and never across it.
        if origin.y + size.height > bounds.height - 8 {
            let above = target.minY - size.height - 10
            origin.y = above >= 8 ? above : max(bounds.height - size.height - 8, 8)
        }
        origin.x = min(max(origin.x, 8), max(bounds.width - size.width - 8, 8))
        host.frame = NSRect(origin: origin, size: size)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        func outline(_ rect: NSRect, filled: Bool) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
            if filled {
                accent.withAlphaComponent(0.12).setFill()
                path.fill()
            }
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        func ring(at point: NSPoint) {
            let path = NSBezierPath(ovalIn: NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
            accent.withAlphaComponent(0.15).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        func show(_ rect: NSRect, filled: Bool) {
            if rect.width < 1, rect.height < 1 { ring(at: rect.origin) } else { outline(rect, filled: filled) }
        }
        for mark in marks {
            // A spot or a region is nothing without its outline. An element is left as it looks.
            if mark.comment.id == lit {
                show(mark.rect, filled: true)
            } else if mark.comment.spot?.kind != .element, mark.comment.spot != nil {
                show(mark.rect, filled: false)
            }
        }
        // Lines being noted are tinted by their own viewer. Anything else gets its outline here.
        if let openRect, let open = NoteWriting.shared.open, open.item == itemID, open.anchor.spot != nil || surface?.canPoint == true { show(openRect, filled: true) }
        if let drag {
            let rect = NSRect(x: min(drag.start.x, drag.now.x), y: min(drag.start.y, drag.now.y),
                              width: abs(drag.now.x - drag.start.x), height: abs(drag.now.y - drag.start.y))
            if rect.width > 4 || rect.height > 4 { outline(rect, filled: true) }
        }
        if let hover {
            show(hover.rect, filled: true)
            drawLabel(hover.label, for: hover.rect)
        }
        for index in marks.indices {
            marks[index].pin = NotePin.draw(marks[index].comment, at: marks[index].pin.origin)
        }
    }

    private func drawLabel(_ text: String, for rect: NSRect) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white]
        let label = text as NSString
        let size = label.size(withAttributes: attributes)
        var box = NSRect(x: rect.minX - 1, y: rect.minY - size.height - 7, width: size.width + 10, height: size.height + 5)
        if rect.width >= box.width + 60, rect.height >= box.height + 6 {
            // Inside the outline, at its top right: what's above the element stays readable, and the right end of
            // a block is where it's least likely to have anything of its own.
            box.origin = NSPoint(x: rect.maxX - box.width - 1, y: rect.minY + 1)
        } else if rect.maxX + box.width + 8 <= bounds.width {
            // Something small: beside it, where a line of text above or below it isn't.
            box.origin = NSPoint(x: rect.maxX + 5, y: rect.midY - box.height / 2)
        } else if box.minY < 2 {
            box.origin.y = rect.maxY + 3
        }
        box.origin.x = min(max(box.minX, 2), max(bounds.width - box.width - 2, 2))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2.5), withAttributes: attributes)
    }
}
