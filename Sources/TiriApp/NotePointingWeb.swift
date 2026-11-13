import AppKit
import TiriCore
import WebKit

/// Asks a page what's at a point, and where things are now. It runs apart from the page's own scripts,
/// which can't see it, and the page never gets the click: the note layer over it takes that.
enum NotePageScript {
    static let source = #"""
    (() => {
      if (window.__tiriNote) return;
      const part = (element) => {
        if (element.id) return '#' + CSS.escape(element.id);
        let text = element.tagName.toLowerCase();
        const parent = element.parentElement;
        if (parent) {
          const same = Array.from(parent.children).filter((child) => child.tagName === element.tagName);
          if (same.length > 1) text += `:nth-of-type(${same.indexOf(element) + 1})`;
        }
        return text;
      };
      const selector = (element) => {
        const parts = [];
        for (let node = element; node && node.nodeType === 1 && parts.length < 6; node = node.parentElement) {
          parts.unshift(part(node));
          if (node.id) break;
        }
        return parts.join(' > ');
      };
      const shown = (element) => (element.innerText || element.getAttribute('aria-label') || element.getAttribute('alt') || '').trim();
      // "The middle card": a selector says where something is in the markup, not which of three alike it is.
      const among = (element) => {
        for (let node = element; node && node !== document.body && node.parentElement; node = node.parentElement) {
          const cls = node.classList[0];
          const same = Array.from(node.parentElement.children).filter((child) => child.tagName === node.tagName && (!cls || child.classList.contains(cls)));
          if (same.length < 2) continue;
          const kind = node.tagName.toLowerCase() + (cls ? '.' + cls : '');
          const heading = node === element ? null : node.querySelector('h1,h2,h3,h4,h5,h6');
          const title = heading ? shown(heading).slice(0, 60) : '';
          const which = `${same.indexOf(node) + 1} of ${same.length} \`${kind}\``;
          return node === element ? `It is ${which}` : `It is in ${which}` + (title ? ` ("${title}")` : '');
        }
        return '';
      };
      const label = (element) => {
        let text = element.tagName.toLowerCase();
        if (element.id) text += '#' + element.id;
        else if (element.classList.length) text += '.' + element.classList[0];
        return text;
      };
      const describe = (element) => {
        const rect = element.getBoundingClientRect();
        let source = element;
        while (source && !(source.dataset && source.dataset.line !== undefined)) source = source.parentElement;
        const where = source ? source.getBoundingClientRect() : rect;
        return {
          selector: selector(element), label: label(element), html: element.outerHTML.slice(0, 1200), text: shown(element).slice(0, 300),
          among: among(element), x: rect.left, y: rect.top, w: rect.width, h: rect.height,
          line: source ? Number(source.dataset.line) : -1, lineEnd: source ? Number(source.dataset.lineEnd) : -1,
          sx: where.left, sy: where.top, sw: where.width, sh: where.height, pageW: innerWidth, pageH: innerHeight
        };
      };
      const under = (x, y) => {
        let element = document.elementFromPoint(x, y);
        // What's inside a shadow root is what's seen, not its host.
        for (let i = 0; i < 8 && element && element.shadowRoot; i++) {
          const inner = element.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === element) break;
          element = inner;
        }
        return element;
      };
      const find = (query) => {
        let element = null;
        try { element = query.selector ? document.querySelector(query.selector) : null; } catch (e) {}
        const wanted = (query.text || '').trim();
        // The markup was rewritten: the same words in the same kind of element is the next best way to find it.
        if (wanted && (!element || shown(element).slice(0, 300) !== wanted)) {
          const tag = (query.selector || '').split(' > ').pop().replace(/[#:.].*$/, '') || '*';
          let again = null;
          try { again = Array.from(document.querySelectorAll(tag)).find((candidate) => shown(candidate).slice(0, 300) === wanted); } catch (e) {}
          if (again) element = again;
        }
        return element;
      };
      window.__tiriNote = {
        at(x, y, depth) {
          let element = under(x, y);
          if (!element || element === document.documentElement || element === document.body) return null;
          for (let i = 0; i < depth && element.parentElement && element.parentElement !== document.body; i++) element = element.parentElement;
          return describe(element);
        },
        rects(queries) {
          return queries.map((query) => {
            if (query.x !== undefined) return [query.x - scrollX, query.y - scrollY, query.w || 0, query.h || 0];
            if (query.line !== undefined) {
              let box = null;
              for (const block of document.querySelectorAll('[data-line]')) {
                const first = Number(block.dataset.line) + 1, last = Number(block.dataset.lineEnd) + 1;
                if (last < query.line || first > query.lineEnd) continue;
                const rect = block.getBoundingClientRect();
                if (!rect.width && !rect.height) continue;
                box = box ? [Math.min(box[0], rect.left), Math.min(box[1], rect.top), Math.max(box[2], rect.right), Math.max(box[3], rect.bottom)]
                          : [rect.left, rect.top, rect.right, rect.bottom];
              }
              return box ? [box[0], box[1], box[2] - box[0], box[3] - box[1]] : null;
            }
            const element = find(query);
            if (!element) return null;
            const rect = element.getBoundingClientRect();
            return rect.width || rect.height ? [rect.left, rect.top, rect.width, rect.height] : null;
          });
        },
        scroll() { return [scrollX, scrollY]; }
      };
    })();
    """#
}

/// The page side of noting, shared by a web page and a rendered document.
final class WebNotes {
    private weak var webView: WKWebView?
    private let root: () -> NSView?
    /// The file, or for a page that isn't one, its address.
    var path: () -> String = { "" }
    var address: () -> String? = { nil }
    /// For a rendered document: the lines of the file a block was made from, so the note is on those.
    var linesOfBlock: ((_ first: Int, _ last: Int) -> ReviewAnchor?)?

    init(webView: WKWebView, root: @escaping () -> NSView?) {
        self.webView = webView
        self.root = root
    }

    /// Points in the page, as its scripts count them, for one view point.
    private var scale: CGFloat {
        guard let webView else { return 1 }
        return max(webView.pageZoom * webView.magnification, 0.01)
    }

    private func pagePoint(_ point: NSPoint) -> NSPoint? {
        guard let webView, let root = root() else { return nil }
        var inView = NoteLayer.point(point, in: root, to: webView)
        if !webView.isFlipped { inView.y = webView.bounds.height - inView.y }
        return NSPoint(x: inView.x / scale, y: inView.y / scale)
    }

    private func layerRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect? {
        guard let webView, let root = root() else { return nil }
        var rect = NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        return NoteLayer.rect(rect, of: webView, in: root)
    }

    private func ask(_ call: String, reply: @escaping (Any?) -> Void) {
        guard let webView else { return reply(nil) }
        webView.evaluateJavaScript(NotePageScript.source + "\nJSON.stringify(\(call))", in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let text = value as? String, let data = text.data(using: .utf8) else { return reply(nil) }
                reply(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            }
        }
    }

    private static func number(_ value: Any?) -> CGFloat { CGFloat((value as? NSNumber)?.doubleValue ?? 0) }

    func target(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void) {
        guard let first = pagePoint(start), let last = pagePoint(end) else { return reply(nil) }
        let path = path(), address = address()
        if start != end {
            // A region of the page as it's scrolled now. What's in the middle of it says what it is.
            let box = NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            ask("[window.__tiriNote.at(\(box.midX), \(box.midY), 0), window.__tiriNote.scroll(), innerWidth, innerHeight]") { [weak self] value in
                guard let self, let parts = value as? [Any], parts.count == 4, let scroll = parts[1] as? [Any], scroll.count == 2,
                      let rect = self.layerRect(x: box.minX, y: box.minY, width: box.width, height: box.height) else { return reply(nil) }
                let middle = parts[0] as? [String: Any]
                let spot = ReviewSpot(kind: .region, selector: middle?["selector"] as? String, shows: (middle?["text"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
                                      x: Double(box.minX + Self.number(scroll[0])), y: Double(box.minY + Self.number(scroll[1])), width: Double(box.width), height: Double(box.height),
                                      fullWidth: Double(Self.number(parts[2])), fullHeight: Double(Self.number(parts[3])), address: address)
                reply(NoteTarget(anchor: ReviewAnchor(path: path, spot: spot), rect: rect, label: ""))
            }
            return
        }
        ask("window.__tiriNote.at(\(first.x), \(first.y), \(depth))") { [weak self] value in
            guard let self, let found = value as? [String: Any], let selector = found["selector"] as? String else { return reply(nil) }
            let line = (found["line"] as? NSNumber)?.intValue ?? -1
            let lineEnd = (found["lineEnd"] as? NSNumber)?.intValue ?? -1
            // Both count from 0, and the block runs to the end of its last line.
            if line >= 0, lineEnd >= line, let anchor = self.linesOfBlock?(line + 1, lineEnd + 1),
               let rect = self.layerRect(x: Self.number(found["sx"]), y: Self.number(found["sy"]), width: Self.number(found["sw"]), height: Self.number(found["sh"])) {
                reply(NoteTarget(anchor: anchor, rect: rect, label: anchor.firstLine == anchor.lastLine ? String(localized: "line \(anchor.firstLine ?? 0)")
                                                                                                         : String(localized: "lines \(anchor.firstLine ?? 0)–\(anchor.lastLine ?? 0)")))
                return
            }
            guard let rect = self.layerRect(x: Self.number(found["x"]), y: Self.number(found["y"]), width: Self.number(found["w"]), height: Self.number(found["h"])) else { return reply(nil) }
            var shows = found["text"] as? String ?? ""
            if let among = found["among"] as? String, !among.isEmpty { shows = shows.isEmpty ? among : shows + "\n" + among }
            let spot = ReviewSpot(kind: .element, selector: selector, html: found["html"] as? String, shows: shows.isEmpty ? nil : shows,
                                  width: Double(Self.number(found["w"])), height: Double(Self.number(found["h"])),
                                  fullWidth: Double(Self.number(found["pageW"])), fullHeight: Double(Self.number(found["pageH"])), address: address)
            reply(NoteTarget(anchor: ReviewAnchor(path: path, spot: spot), rect: rect, label: found["label"] as? String ?? ""))
        }
    }

    func rects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void) {
        var queries: [[String: Any]] = []
        for anchor in anchors {
            if let spot = anchor.spot {
                switch spot.kind {
                case .element:
                    // Only the words the element itself showed: the line about its neighbours was added for the agent.
                    let text = spot.shows?.components(separatedBy: "\nIt is ").first ?? ""
                    queries.append(["selector": spot.selector ?? "", "text": text.hasPrefix("It is ") ? "" : text])
                case .point, .region:
                    queries.append(["x": spot.x ?? 0, "y": spot.y ?? 0, "w": spot.width ?? 0, "h": spot.height ?? 0])
                }
            } else if let first = anchor.firstLine {
                queries.append(["line": first, "lineEnd": anchor.lastLine ?? first])
            } else {
                queries.append(["selector": ""])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: queries), let json = String(data: data, encoding: .utf8) else { return reply(anchors.map { _ in nil }) }
        ask("window.__tiriNote.rects(\(json))") { [weak self] value in
            guard let self, let list = value as? [Any], list.count == anchors.count else { return reply(anchors.map { _ in nil }) }
            reply(list.map { item in
                guard let numbers = item as? [Any], numbers.count == 4 else { return nil }
                return self.layerRect(x: Self.number(numbers[0]), y: Self.number(numbers[1]), width: Self.number(numbers[2]), height: Self.number(numbers[3]))
            })
        }
    }

    /// A picture of the thing with some of what's around it, and the thing outlined: which card, not just a card.
    func finish(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) {
        guard let webView, let root = root(), var spot = target.anchor.spot else { return reply(target.anchor) }
        let inRoot = root.isFlipped ? target.rect : NSRect(x: target.rect.minX, y: root.bounds.height - target.rect.maxY, width: target.rect.width, height: target.rect.height)
        let thing = webView.convert(inRoot, from: root)
        // Enough of what's around it to tell it from its neighbours.
        let around = thing.insetBy(dx: -max(140, min(thing.width * 0.5, 200)), dy: -max(110, min(thing.height * 0.5, 160))).intersection(webView.bounds)
        guard around.width > 4, around.height > 4 else { return reply(target.anchor) }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = around
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated {
                var anchor = target.anchor
                guard let image else { return reply(anchor) }
                // The snapshot counts from its top left, as a flipped view does.
                let mark = NSRect(x: thing.minX - around.minX, y: webView.isFlipped ? thing.minY - around.minY : around.maxY - thing.maxY, width: thing.width, height: thing.height)
                spot.picture = NotePictures.save(image, marking: mark, in: around.size)
                anchor.spot = spot
                reply(anchor)
            }
        }
    }
}

/// Pictures that go with notes: a crop with the place marked, as a file an agent can open.
enum NotePictures {
    /// `mark` counts from the picture's top left, in a picture `size` points across.
    @MainActor static func save(_ image: NSImage, marking mark: NSRect?, in size: NSSize) -> String? {
        let picture = NSImage(size: size)
        picture.lockFocusFlipped(true)
        // The canvas counts from the top, as the mark does, and the picture is drawn the right way up in it.
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let mark {
            let color = NSColor(srgbRed: 0.84, green: 0.2, blue: 0.42, alpha: 1)
            color.setStroke()
            if mark.width < 1, mark.height < 1 {
                let ring = NSBezierPath(ovalIn: NSRect(x: mark.minX - 14, y: mark.minY - 14, width: 28, height: 28))
                ring.lineWidth = 3
                ring.stroke()
            } else {
                let outline = NSBezierPath(roundedRect: mark.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
                outline.lineWidth = 2.5
                outline.stroke()
            }
        }
        picture.unlockFocus()
        return AppModel.shared.savePastedImage(picture)
    }
}

// MARK: - A web page

extension WebController: NoteSurface {
    /// A plugin's panel is the plugin's own screen, not an agent's work.
    var canPoint: Bool { panel == nil }

    func noteTarget(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void) {
        pageNotes.target(from: start, to: end, depth: depth, reply: reply)
    }

    func noteRects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void) {
        pageNotes.rects(for: anchors, reply: reply)
    }

    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) {
        pageNotes.finish(target, reply: reply)
    }

    func notesToMark() -> [ReviewComment] {
        model.reviewComments(on: notePath).filter { $0.spot != nil }
    }
}

// MARK: - A rendered document

extension MarkdownController: NoteSurface {
    var canPoint: Bool { noteWebView != nil }

    func noteTarget(from start: NSPoint, to end: NSPoint, depth: Int, reply: @escaping (NoteTarget?) -> Void) {
        guard noteWebView != nil else { return reply(nil) }
        // A document is its lines: a drag is the blocks from where it began to where it ended.
        guard start != end else { return pageNotes.target(from: start, to: start, depth: depth, reply: reply) }
        pageNotes.target(from: start, to: start, depth: 0) { [weak self] first in
            self?.pageNotes.target(from: end, to: end, depth: 0) { last in
                guard let first, let last, let a = first.anchor.firstLine, let b = last.anchor.firstLine, first.anchor.spot == nil, last.anchor.spot == nil else { return reply(first) }
                let low = min(a, b), high = max(first.anchor.lastLine ?? a, last.anchor.lastLine ?? b)
                let anchor = ReviewAnchor(path: first.anchor.path, firstLine: low, lastLine: high, excerpt: ReviewQuote.lines(low, high, of: first.anchor.path))
                reply(NoteTarget(anchor: anchor, rect: first.rect.union(last.rect), label: String(localized: "lines \(low)–\(high)")))
            }
        }
    }

    func noteRects(for anchors: [ReviewAnchor], reply: @escaping ([NSRect?]) -> Void) {
        guard noteWebView != nil else { return reply(anchors.map { _ in nil }) }
        pageNotes.rects(for: anchors, reply: reply)
    }

    func finishNote(_ target: NoteTarget, reply: @escaping (ReviewAnchor) -> Void) {
        target.anchor.spot == nil ? reply(target.anchor) : pageNotes.finish(target, reply: reply)
    }

    func notesToMark() -> [ReviewComment] {
        guard noteWebView != nil else { return [] }
        return model.reviewComments(on: path).filter { $0.commit == nil && ($0.spot != nil || $0.firstLine != nil) }
    }
}
