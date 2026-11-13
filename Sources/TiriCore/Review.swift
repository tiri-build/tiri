import Foundation

/// What a note points at when that isn't lines of text: an element of a page, or a place in a picture or a PDF.
/// It carries more than one way of finding the thing again, because an agent rewrites what was pointed at.
public struct ReviewSpot: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case element
        case point
        case region
    }

    public var kind: Kind
    /// For an element: how a script finds it, its markup, and the words it shows.
    public var selector: String?
    public var html: String?
    public var shows: String?
    /// Where it is, in the picture's or the page's own points from the top left, and how big that whole is.
    /// A point has no width or height.
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var fullWidth: Double?
    public var fullHeight: Double?
    /// The page of a PDF, counting from 1.
    public var page: Int?
    /// A picture of it with the place marked, as a file an agent can open.
    public var picture: String?
    /// The address, when the note is on a page that isn't a file.
    public var address: String?

    public init(kind: Kind, selector: String? = nil, html: String? = nil, shows: String? = nil, x: Double? = nil, y: Double? = nil,
                width: Double? = nil, height: Double? = nil, fullWidth: Double? = nil, fullHeight: Double? = nil, page: Int? = nil,
                picture: String? = nil, address: String? = nil) {
        self.kind = kind
        self.selector = selector
        self.html = html
        self.shows = shows
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.page = page
        self.picture = picture
        self.address = address
    }

    /// A few words for where a list or a box says what the note is on.
    public var label: String {
        switch kind {
        case .element:
            if let shows = shows?.split(whereSeparator: \.isNewline).first.map(String.init), !shows.isEmpty { return "“\(shows.prefix(40))”" }
            return selector?.components(separatedBy: " > ").last ?? String(localized: "an element")
        case .point:
            return page.map { String(localized: "a spot on page \($0)") } ?? String(localized: "a spot")
        case .region:
            return page.map { String(localized: "a region on page \($0)") } ?? String(localized: "a region")
        }
    }
}

/// A remark on an agent's work, waiting to go to it with the others. Reading a change usually
/// raises several, and sending each one as you go interrupts both you and the agent.
public struct ReviewComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    /// Counting from 1, in the file as it was when you commented. Nil for a whole file.
    public var firstLine: Int?
    public var lastLine: Int?
    /// The lines as they were, so the comment can follow them when an agent moves them.
    public var excerpt: String?
    /// What the comment is on when it isn't simply lines of the file, like a diff's rows or a
    /// PDF's text. It's what the agent reads.
    public var quote: String?
    public var quoteIsDiff: Bool
    /// The commit whose diff it's on, by its full hash, if it's on one.
    public var commit: String?
    /// What it points at, when that isn't text.
    public var spot: ReviewSpot?
    public var text: String
    public var created: Date
    /// When it went to an agent. It stays where it was made after that, to check the answer against.
    public var sent: Date?

    public init(id: String = TiriID.make("c"), path: String, firstLine: Int? = nil, lastLine: Int? = nil,
                excerpt: String? = nil, quote: String? = nil, quoteIsDiff: Bool = false, commit: String? = nil,
                spot: ReviewSpot? = nil, text: String, created: Date = Date(), sent: Date? = nil) {
        self.id = id
        self.path = path
        self.firstLine = firstLine
        self.lastLine = lastLine ?? firstLine
        self.excerpt = excerpt
        self.quote = quote
        self.quoteIsDiff = quoteIsDiff
        self.commit = commit
        self.spot = spot
        self.text = text
        self.created = created
        self.sent = sent
    }

    public var summary: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// What a comment would be attached to, before anything has been written.
public struct ReviewAnchor: Equatable, Sendable {
    public var path: String
    public var firstLine: Int?
    public var lastLine: Int?
    public var excerpt: String?
    public var quote: String?
    public var quoteIsDiff: Bool
    public var commit: String?
    public var spot: ReviewSpot?

    public init(path: String, firstLine: Int? = nil, lastLine: Int? = nil, excerpt: String? = nil,
                quote: String? = nil, quoteIsDiff: Bool = false, commit: String? = nil, spot: ReviewSpot? = nil) {
        self.path = path
        self.firstLine = firstLine
        self.lastLine = lastLine ?? firstLine
        self.excerpt = excerpt
        self.quote = quote
        self.quoteIsDiff = quoteIsDiff
        self.commit = commit
        self.spot = spot
    }

    public func comment(text: String) -> ReviewComment {
        ReviewComment(path: path, firstLine: firstLine, lastLine: lastLine, excerpt: excerpt, quote: quote,
                      quoteIsDiff: quoteIsDiff, commit: commit, spot: spot, text: text)
    }

    public var description: String {
        let name = (path as NSString).lastPathComponent
        if let spot { return String(localized: "\(name), \(spot.label)") }
        guard let firstLine else { return quote == nil ? name : String(localized: "the selection in \(name)") }
        let last = lastLine ?? firstLine
        return last == firstLine ? String(localized: "\(name), line \(firstLine)") : String(localized: "\(name), lines \(firstLine)–\(last)")
    }
}

public enum ReviewLocator {
    public enum Place: Equatable, Sendable {
        case lines(ClosedRange<Int>)
        /// The lines aren't in the file any more. The comment still stands, and says what it was on.
        case gone
        case wholeFile
    }

    /// Where a comment's lines are now: the copy of them nearest to where they were.
    public static func place(of comment: ReviewComment, in text: String) -> Place {
        guard let first = comment.firstLine else { return .wholeFile }
        let last = comment.lastLine ?? first
        guard let excerpt = comment.excerpt, !excerpt.isEmpty else { return .lines(first...max(first, last)) }
        let wanted = lines(of: excerpt)
        guard !wanted.isEmpty else { return .lines(first...max(first, last)) }
        let all = lines(of: text)
        guard all.count >= wanted.count else { return .gone }
        var best: Int?
        for start in 0...(all.count - wanted.count) where all[start] == wanted[0] {
            guard wanted.indices.allSatisfy({ all[start + $0] == wanted[$0] }) else { continue }
            let line = start + 1
            if best == nil || abs(line - first) < abs(best! - first) { best = line }
        }
        guard let best else { return .gone }
        return .lines(best...(best + wanted.count - 1))
    }

    private static func lines(of text: String) -> [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}

/// The batch, written out as one message for an agent to work through.
public enum ReviewMessage {
    /// A long excerpt would bury the comment. The path and lines are enough for the rest.
    static let maximumExcerptLines = 30

    /// The words, and apart from them the pictures they mention: a picture reaches an agent as an attachment of its own.
    public struct Parts: Equatable, Sendable {
        public var text: String
        public var pictures: [String]
    }

    public static func text(comments: [ReviewComment], cwd: String, fileText: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> String {
        parts(comments: comments, cwd: cwd, fileText: fileText).text
    }

    /// Numbered in the order given, which is the order of the marks on screen, so "3" means the same thing in both.
    public static func parts(comments: [ReviewComment], cwd: String, fileText: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Parts {
        var sections: [String] = []
        var pictures: [String] = []
        for (index, comment) in comments.enumerated() {
            if let spot = comment.spot {
                sections.append(section(index + 1, comment, spot, cwd: cwd))
                if let picture = spot.picture { pictures.append(picture) }
                continue
            }
            var place = ReviewLocator.Place.wholeFile
            if comment.firstLine != nil {
                if let text = fileText(comment.path) {
                    place = ReviewLocator.place(of: comment, in: text)
                } else {
                    place = .gone
                }
            }
            var header = "\(index + 1). " + relative(comment.path, to: cwd)
            switch place {
            case .lines(let range):
                header += range.count == 1 ? ":\(range.lowerBound)" : ":\(range.lowerBound)-\(range.upperBound)"
            case .gone:
                header += " (this code has changed since the note)"
            case .wholeFile:
                break
            }
            if let commit = comment.commit { header += " (in commit \(commit.prefix(7)))" }
            var section = [header]
            if let quoted = comment.quote ?? comment.excerpt {
                let language = comment.quoteIsDiff ? "diff" : (comment.quote == nil ? (comment.path as NSString).pathExtension : "")
                section.append(fenced(quoted, language: language))
            }
            section.append(comment.text)
            sections.append(section.joined(separator: "\n"))
        }
        let intro = comments.count == 1 ? "A note on your work:" : "Notes on your work. Please go through each one:"
        return Parts(text: intro + "\n\n" + sections.joined(separator: "\n\n") + "\n", pictures: pictures)
    }

    /// A note on something pointed at: where it is in words an agent can act on, then the picture, then the note.
    private static func section(_ number: Int, _ comment: ReviewComment, _ spot: ReviewSpot, cwd: String) -> String {
        func whole(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "?" }
        var header = "\(number). \(spot.address ?? relative(comment.path, to: cwd))"
        if let page = spot.page { header += ", page \(page)" }
        var lines: [String] = []
        switch spot.kind {
        case .element:
            if let selector = spot.selector { header += ", the element `\(selector)`" }
            if let width = spot.width, let height = spot.height { header += " (\(whole(width))×\(whole(height)))" }
            lines.append(header)
            if let html = spot.html, !html.isEmpty { lines.append(fenced(html, language: "html")) }
            if let shows = spot.shows, !shows.isEmpty { lines.append("It shows: \(shows)") }
        case .point:
            header += " at x \(whole(spot.x)), y \(whole(spot.y))"
            if spot.fullWidth != nil { header += " of \(whole(spot.fullWidth))×\(whole(spot.fullHeight))" }
            lines.append(header)
            if let shows = spot.shows, !shows.isEmpty { lines.append("Near: \(shows)") }
        case .region:
            header += ", the region at x \(whole(spot.x)), y \(whole(spot.y)), \(whole(spot.width))×\(whole(spot.height))"
            if spot.fullWidth != nil { header += " of \(whole(spot.fullWidth))×\(whole(spot.fullHeight))" }
            lines.append(header)
            if let shows = spot.shows, !shows.isEmpty { lines.append("It holds: \(shows)") }
        }
        if let picture = spot.picture {
            lines.append(spot.kind == .point ? "Picture, with the spot ringed: \(picture)" : "Picture: \(picture)")
        }
        if !comment.text.isEmpty { lines.append(comment.text) }
        return lines.joined(separator: "\n")
    }

    /// A fence longer than any run of backticks inside it, which code can contain.
    static func fenced(_ text: String, language: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.count > maximumExcerptLines {
            let hidden = lines.count - maximumExcerptLines
            lines = Array(lines.prefix(maximumExcerptLines)) + ["… \(hidden) more line\(hidden == 1 ? "" : "s")"]
        }
        let body = lines.joined(separator: "\n")
        var longest = 0
        var run = 0
        for character in body {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + body + "\n" + fence
    }

    static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

extension Workspace {
    public func reviewComments(on path: String) -> [ReviewComment] {
        review.filter { $0.path == path }
    }

    /// The notes still to go to an agent, in the order they were made.
    public var pendingNotes: [ReviewComment] { review.filter { $0.sent == nil } }

    /// The number on a waiting note's mark, which is its number in the message too. A sent note has none.
    public func noteNumber(_ id: String) -> Int? {
        pendingNotes.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}
