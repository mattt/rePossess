import Foundation
import Testing

@testable import RePossessFormat

@Suite struct StrokeHashTests {
    func hash(_ page: PageBuilder) throws -> String? {
        pageContent(try page.bytes()).strokeHash
    }

    func ink(_ points: [(Double, Double)], text: String? = nil) -> PageBuilder {
        var page = PageBuilder()
        if let text { page.paragraphs = [StyledParagraph(.plain, text)] }
        page.groups = [.init(lines: [PageBuilder.stroke(points)])]
        return page
    }

    @Test func aPageWithoutStrokesHasNoHash() throws {
        var page = PageBuilder()
        page.paragraphs = [StyledParagraph(.plain, "Typed only")]
        #expect(try hash(page) == nil)
        #expect(try hash(PageBuilder()) == nil)
    }

    @Test func theSameStrokesHaveTheSameHash() throws {
        let a = try #require(try hash(ink([(0, 0), (40, 40)])))
        #expect(a.count == 64)
        #expect(try hash(ink([(0, 0), (40, 40)])) == a)
    }

    @Test func aMovedPointOrAnotherToolChangesTheHash() throws {
        let a = try hash(ink([(0, 0), (40, 40)]))
        #expect(try hash(ink([(0, 0), (40, 41)])) != a)
        var pencil = PageBuilder()
        pencil.groups = [.init(lines: [PageBuilder.stroke([(0, 0), (40, 40)], tool: .pencil2)])]
        #expect(try hash(pencil) != a)
    }

    @Test func typedTextDoesNotChangeTheHash() throws {
        #expect(try hash(ink([(0, 600), (40, 640)], text: "One")) == hash(ink([(0, 600), (40, 640)], text: "Two")))
    }

    @Test func erasersAreLeftOut() throws {
        var page = ink([(0, 0), (40, 40)])
        page.groups[0].lines.append(PageBuilder.stroke([(5, 5), (6, 6)], tool: .eraser))
        #expect(try hash(page) == hash(ink([(0, 0), (40, 40)])))
    }
}
