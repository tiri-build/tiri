import Foundation
import Testing
@testable import TiriCore

@Suite struct ReviewSpotTests {
    private let cwd = "/p"

    @Test func anElementSaysWhereItIsAndWhatItShows() {
        let spot = ReviewSpot(kind: .element, selector: "main > section:nth-of-type(2) > button#buy-team", html: "<button id=\"buy-team\">Choose Team</button>",
                              shows: "Choose Team", width: 118.4, height: 38, picture: "/notes/1.png")
        let parts = ReviewMessage.parts(comments: [ReviewComment(path: "/p/site/pricing.html", spot: spot, text: "Make this pink.")], cwd: cwd)
        #expect(parts.text.contains("1. site/pricing.html, the element `main > section:nth-of-type(2) > button#buy-team` (118×38)"))
        #expect(parts.text.contains("```html\n<button id=\"buy-team\">Choose Team</button>\n```"))
        #expect(parts.text.contains("It shows: Choose Team"))
        #expect(parts.text.contains("Picture: /notes/1.png\nMake this pink."))
        #expect(parts.pictures == ["/notes/1.png"])
    }

    @Test func aSpotOnAPictureGivesItsPlaceInThePicturesOwnSize() {
        let spot = ReviewSpot(kind: .point, x: 180.2, y: 164, fullWidth: 390, fullHeight: 655, picture: "/notes/2.png")
        let text = ReviewMessage.text(comments: [ReviewComment(path: "/p/shots/phone.png", spot: spot, text: "Three lines.")], cwd: cwd)
        #expect(text.contains("1. shots/phone.png at x 180, y 164 of 390×655\nPicture, with the spot ringed: /notes/2.png\nThree lines."))
    }

    @Test func aRegionOfAPDFSaysWhichPage() {
        let spot = ReviewSpot(kind: .region, shows: "Total due", x: 40, y: 300, width: 200, height: 60, fullWidth: 612, fullHeight: 792, page: 3)
        let text = ReviewMessage.text(comments: [ReviewComment(path: "/p/invoice.pdf", spot: spot, text: "Wrong sum.")], cwd: cwd)
        #expect(text.contains("1. invoice.pdf, page 3, the region at x 40, y 300, 200×60 of 612×792\nIt holds: Total due\nWrong sum."))
    }

    @Test func aPageThatIsntAFileGoesByItsAddress() {
        let spot = ReviewSpot(kind: .element, selector: "h1", address: "http://localhost:3000/pricing")
        let text = ReviewMessage.text(comments: [ReviewComment(path: "/p", spot: spot, text: "Shorter.")], cwd: cwd)
        #expect(text.contains("1. http://localhost:3000/pricing, the element `h1`\nShorter."))
    }

    @Test func numbersRunAcrossLinesAndSpots() {
        let comments = [
            ReviewComment(path: "/p/a.js", firstLine: 2, excerpt: "b", text: "first"),
            ReviewComment(path: "/p/a.html", spot: ReviewSpot(kind: .element, selector: "h1"), text: "second"),
        ]
        let text = ReviewMessage.text(comments: comments, cwd: cwd) { _ in "a\nb\n" }
        #expect(text.contains("1. a.js:2"))
        #expect(text.contains("2. a.html, the element `h1`"))
    }

    @Test func aNoteWithNoWordsStillPoints() {
        let text = ReviewMessage.text(comments: [ReviewComment(path: "/p/a.html", spot: ReviewSpot(kind: .element, selector: "h1"), text: "")], cwd: cwd)
        #expect(text.hasSuffix("the element `h1`\n"))
    }

    @Test func notesSavedBeforeSpotsStillRead() throws {
        let old = #"{"id":"c-1","path":"/p/a.js","firstLine":2,"lastLine":2,"quoteIsDiff":false,"text":"x","created":0}"#
        let comment = try JSONDecoder().decode(ReviewComment.self, from: Data(old.utf8))
        #expect(comment.spot == nil)
        #expect(comment.firstLine == 2)
    }

    @Test func aSpotSurvivesBeingSaved() throws {
        let spot = ReviewSpot(kind: .region, x: 1, y: 2, width: 3, height: 4, page: 2, picture: "/n.png")
        let comment = ReviewComment(path: "/p/a.pdf", spot: spot, text: "x")
        let back = try JSONDecoder().decode(ReviewComment.self, from: JSONEncoder().encode(comment))
        #expect(back.spot == spot)
    }

    @Test func labelsAreShort() {
        #expect(ReviewSpot(kind: .element, selector: "main > button#buy-team", shows: "Choose Team\nmore").label == "“Choose Team”")
        #expect(ReviewSpot(kind: .element, selector: "main > button#buy-team").label == "button#buy-team")
        #expect(ReviewAnchor(path: "/p/phone.png", spot: ReviewSpot(kind: .point)).description == "phone.png, a spot")
    }
}
