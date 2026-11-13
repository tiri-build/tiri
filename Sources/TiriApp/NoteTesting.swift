import AppKit
import TiriCore

/// Notes, driven the way a pointer and keys would, for a test copy that has neither.
enum NoteTesting {
    static func run(_ request: ControlRequest, model: AppModel) throws -> JSONValue {
        guard ProcessInfo.processInfo.environment["TIRI_DEV_OFFSCREEN"] == "1" else { throw ControlHandler.ControlFailure("Only for a test copy.") }
        let action = request.args["action"]?.stringValue ?? ""
        let values = request.args["values"]?.arrayValue?.compactMap(\.stringValue) ?? []
        func number(_ index: Int) -> CGFloat? { index < values.count ? Double(values[index]).map { CGFloat($0) } : nil }
        let writing = NoteWriting.shared
        switch action {
        case "type":
            writing.text = values.joined(separator: " ")
            return .object([:])
        case "add":
            model.commitNote()
            return .object([:])
        case "send":
            model.commitNote(sending: true)
            return .object([:])
        case "esc":
            model.closeNote()
            return .object([:])
        case "state":
            return .object([
                "open": .string(writing.open?.anchor.description ?? ""),
                "text": .string(writing.text),
                "waiting": .int(model.active.pendingNotes.count),
                "sent": .int(model.active.review.count - model.active.pendingNotes.count),
            ])
        default:
            break
        }
        guard let id = model.active.peek?.id ?? model.active.focused.active, let controller = model.existingController(for: id) else {
            throw ControlHandler.ControlFailure("There's nothing in front to note.")
        }
        let text = (controller as? TextController) ?? (controller as? MarkdownController)?.shownSource
        let diff = controller as? DiffController
        switch action {
        case "hover":
            let line = number(0).map { Int($0) }
            text?.hoverGutterForTest(line: line)
            diff?.hoverGutterForTest(row: line)
        case "lines":
            guard let first = number(0).map({ Int($0) }) else { throw ControlHandler.ControlFailure("usage: tiri dev-note lines <first> [<last>]") }
            let last = number(1).map { Int($0) } ?? first
            if let text { text.beginNote(lines: first...max(first, last)) } else if let diff { diff.noteForTest(rows: first...max(first, last)) } else {
                throw ControlHandler.ControlFailure("What's in front has no lines.")
            }
        case "latch":
            model.togglePointing(id)
        case "hoverat":
            guard let layer = NoteLayer.existing(for: id), let x = number(0), let y = number(1) else { throw ControlHandler.ControlFailure("usage: tiri dev-note hoverat <x> <y> [<depth>]") }
            layer.hoverForTest(at: NSPoint(x: x, y: y), depth: number(2).map { Int($0) } ?? 0)
        case "point":
            guard let layer = NoteLayer.existing(for: id), let x = number(0), let y = number(1) else { throw ControlHandler.ControlFailure("usage: tiri dev-note point <x> <y> [<x2> <y2>]") }
            let start = NSPoint(x: x, y: y)
            layer.point(from: start, to: NSPoint(x: number(2) ?? x, y: number(3) ?? y))
        case "edit":
            guard let wanted = number(0).map({ Int($0) }), wanted >= 1, wanted <= model.active.pendingNotes.count else { throw ControlHandler.ControlFailure("No waiting note with that number.") }
            model.editNote(model.active.pendingNotes[wanted - 1], in: id)
        default:
            throw ControlHandler.ControlFailure("Unknown action.")
        }
        return .object(["size": .string("\(Int(controller.view.bounds.width))x\(Int(controller.view.bounds.height))")])
    }
}
