import AppKit
import PDFKit
import SwiftUI
import TiriCore

/// In a viewer's bar: the next click notes what it's on. Holding ⌥ does the same without pressing this.
struct PointButton: View {
    let item: ItemID
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = NoteWriting.shared.pointing.contains(item)
        Button {
            model.togglePointing(item)
        } label: {
            Image(systemName: "scope")
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.accentColor : .secondary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .help(on ? String(localized: "Click what you mean, or drag across it. Esc stops") : String(localized: "Point at something to note it. Holding ⌥ does the same"))
        .accessibilityLabel("Point to Note")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension NotePictures {
    /// Part of a picture, counted from its top left in its own points, no wider than an agent needs.
    /// Returns it with how much it was shrunk, for placing a mark on it.
    @MainActor static func crop(_ image: NSImage, to wanted: NSRect) -> (picture: NSImage, scale: CGFloat)? {
        let whole = NSRect(origin: .zero, size: image.size)
        let rect = wanted.intersection(whole)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = min(1, 1100 / rect.width, 1100 / rect.height)
        let size = NSSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let picture = NSImage(size: size)
        picture.lockFocus()
        // An image counts from its bottom left.
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(x: rect.minX, y: image.size.height - rect.maxY, width: rect.width, height: rect.height),
                   operation: .copy, fraction: 1)
        picture.unlockFocus()
        return (picture, scale)
    }

    /// What's around a spot or a region, with it marked. `place` counts from the picture's top left.
    @MainActor static func save(around place: NSRect, of image: NSImage) -> String? {
        let isSpot = place.width < 1 && place.height < 1
        let wanted = isSpot ? NSRect(x: place.minX - 320, y: place.minY - 240, width: 640, height: 480)
                            : place.insetBy(dx: -max(60, place.width * 0.25), dy: -max(60, place.height * 0.25))
        let shown = wanted.intersection(NSRect(origin: .zero, size: image.size))
        guard let cropped = crop(image, to: shown) else { return nil }
        let mark = NSRect(x: (place.minX - shown.minX) * cropped.scale, y: (place.minY - shown.minY) * cropped.scale,
                          width: place.width * cropped.scale, height: place.height * cropped.scale)
        return save(cropped.picture, marking: mark, in: cropped.picture.size)
    }
}

// MARK: - A picture

extension ImageController: NoteSurface {
    /// The picture's own pixels for each point it's drawn at before any zoom.
    private var pixelsPerPoint: CGFloat {
        guard let rep = imageView.image?.representations.first, imageView.bounds.width > 0, rep.pixelsWide > 0 else { return 1 }
        return CGFloat(rep.pixelsWide) / imageView.bounds.width
    }

    /// A point in the layer, on the picture, counted from the picture's top left in its points.
    private func onPicture(_ point: NSPoint, clamped: Bool) -> NSPoint? {
        guard imageView.image != nil else { return nil }
        let inImage = NoteLayer.point(point, in: view, to: imageView)
        var found = NSPoint(x: inImage.x, y: imageView.isFlipped ? inImage.y : imageView.bounds.height - inImage.y)
        if clamped {
            found.x = min(max(found.x, 0), imageView.bounds.width)
            found.y = min(max(found.y, 0), imageView.bounds.height)
        }
        guard found.x >= 0, found.y >= 0, found.x <= imageView.bounds.width, found.y <= imageView.bounds.height else { return nil }
        return found
    }

    private func layerRect(_ rect: NSRect) -> NSRect {
        let inImage = imageView.isFlipped ? rect : NSRect(x: rect.minX, y: imageView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return NoteLayer.rect(inImage, of: imageView, in: view)
    }

    private func place(of spot: ReviewSpot) -> NSRect {
        let factor = pixelsPerPoint
        return NSRect(x: CGFloat(spot.x ?? 0) / factor, y: CGFloat(spot.y ?? 0) / factor, width: CGFloat(spot.width ?? 0) / factor, height: CGFloat(spot.height ?? 0) / factor)
    }

    func noteTarget(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void) {
        guard let first = onPicture(start, clamped: false) else { return reply(nil) }
        let factor = pixelsPerPoint
        let whole = imageView.bounds.size
        var spot = ReviewSpot(kind: .point, x: Double(first.x * factor), y: Double(first.y * factor),
                              fullWidth: Double(whole.width * factor), fullHeight: Double(whole.height * factor))
        var rect = NSRect(origin: first, size: .zero)
        if start != end, let last = onPicture(end, clamped: true) {
            rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            spot.kind = .region
            spot.x = Double(rect.minX * factor)
            spot.y = Double(rect.minY * factor)
            spot.width = Double(rect.width * factor)
            spot.height = Double(rect.height * factor)
        }
        reply(NoteTarget(anchor: ReviewAnchor(path: path, spot: spot), rect: layerRect(rect), label: ""))
    }

    func noteRects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void) {
        reply(anchors.map { anchor in
            guard let spot = anchor.spot, imageView.image != nil else { return nil }
            return layerRect(place(of: spot))
        })
    }

    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) {
        var anchor = target.anchor
        if let image = imageView.image, var spot = anchor.spot {
            spot.picture = NotePictures.save(around: place(of: spot), of: image)
            anchor.spot = spot
        }
        reply(anchor)
    }

    func notesToMark() -> [ReviewComment] {
        AppModel.shared.reviewComments(on: path).filter { $0.spot != nil }
    }
}

// MARK: - A PDF

extension PDFController: NoteSurface {
    /// A point in the layer, on a page, counted from that page's top left.
    private func onPage(_ point: NSPoint, of wanted: PDFPage? = nil) -> (page: PDFPage, point: NSPoint)? {
        let inView = NoteLayer.point(point, in: view, to: pdfView)
        guard let page = wanted ?? pdfView.page(for: inView, nearest: false) else { return nil }
        let onPage = pdfView.convert(inView, to: page)
        let box = page.bounds(for: .cropBox)
        let found = NSPoint(x: min(max(onPage.x - box.minX, 0), box.width), y: min(max(box.maxY - onPage.y, 0), box.height))
        return (page, found)
    }

    private func layerRect(_ rect: NSRect, on page: PDFPage) -> NSRect {
        let box = page.bounds(for: .cropBox)
        let onPage = NSRect(x: rect.minX + box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height)
        return NoteLayer.rect(pdfView.convert(onPage, from: page), of: pdfView, in: view)
    }

    private func place(of spot: ReviewSpot) -> NSRect {
        NSRect(x: CGFloat(spot.x ?? 0), y: CGFloat(spot.y ?? 0), width: CGFloat(spot.width ?? 0), height: CGFloat(spot.height ?? 0))
    }

    func noteTarget(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void) {
        guard let document = pdfView.document, let first = onPage(start) else { return reply(nil) }
        let box = first.page.bounds(for: .cropBox)
        var spot = ReviewSpot(kind: .point, x: Double(first.point.x), y: Double(first.point.y), fullWidth: Double(box.width), fullHeight: Double(box.height),
                              page: document.index(for: first.page) + 1)
        var rect = NSRect(origin: first.point, size: .zero)
        let onLine = NSPoint(x: first.point.x + box.minX, y: box.maxY - first.point.y)
        var shows = first.page.selectionForLine(at: onLine)?.string
        if start != end, let last = onPage(end, of: first.page) {
            rect = NSRect(x: min(first.point.x, last.point.x), y: min(first.point.y, last.point.y),
                          width: abs(last.point.x - first.point.x), height: abs(last.point.y - first.point.y))
            spot.kind = .region
            spot.x = Double(rect.minX)
            spot.y = Double(rect.minY)
            spot.width = Double(rect.width)
            spot.height = Double(rect.height)
            shows = first.page.selection(for: NSRect(x: rect.minX + box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height))?.string
        }
        let words = shows?.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) ?? ""
        spot.shows = words.isEmpty ? nil : String(words.prefix(160))
        reply(NoteTarget(anchor: ReviewAnchor(path: path, spot: spot), rect: layerRect(rect, on: first.page), label: ""))
    }

    func noteRects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void) {
        let document = pdfView.document
        reply(anchors.map { anchor in
            guard let spot = anchor.spot, let number = spot.page, let page = document?.page(at: number - 1) else { return nil }
            return layerRect(place(of: spot), on: page)
        })
    }

    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) {
        var anchor = target.anchor
        if var spot = anchor.spot, let number = spot.page, let page = pdfView.document?.page(at: number - 1) {
            let box = page.bounds(for: .cropBox)
            // Twice the page's points, so small print can still be read in the picture.
            let drawn = page.thumbnail(of: NSSize(width: box.width * 2, height: box.height * 2), for: .cropBox)
            let factor = drawn.size.width / max(box.width, 1)
            let where_ = place(of: spot)
            spot.picture = NotePictures.save(around: NSRect(x: where_.minX * factor, y: where_.minY * factor, width: where_.width * factor, height: where_.height * factor), of: drawn)
            anchor.spot = spot
        }
        reply(anchor)
    }

    func notesToMark() -> [ReviewComment] {
        AppModel.shared.reviewComments(on: path).filter { $0.spot != nil }
    }

    func revealNote(_ anchor: ReviewAnchor) {
        guard let spot = anchor.spot, let number = spot.page, let page = pdfView.document?.page(at: number - 1) else { return }
        let box = page.bounds(for: .cropBox)
        // A little above the place, so it isn't under the bar at the top.
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: box.minX, y: min(box.maxY - CGFloat(spot.y ?? 0) + 160, box.maxY))))
    }
}
