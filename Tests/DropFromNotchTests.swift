import AppKit
import XCTest
@testable import NotchDeck

/// **Dropping from a Mac's own notch.** On the top edge of a display with a
/// hardware notch, the bar grows down out of it: one centred shape that spans
/// the hole, everything it draws below the hole's depth, and nothing of it
/// showing past the hole at rest.
@MainActor
final class DropFromNotchTests: XCTestCase {
    private struct MacBook: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1512, height: 950)
        var hardwareNotch: HardwareNotch? { HardwareNotch(width: 185, height: 32) }
        var displayIdentifier: String? { "macbook" }
    }

    private struct Plain: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1512, height: 982)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1512, height: 950)
        var displayIdentifier: String? { "plain" }
    }

    private func model(style: TopEdgeStyle = .dropDown, cells: Int = 4, tools: Bool = true,
                       open: Bool = true, screen: ScreenDescribing = MacBook(),
                       edge: NotchEdge = .top) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.topEdgeStyle = style
        model.updateSnapshots((0..<cells).map {
            ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude, fidelity: .official,
                             status: .ok, windows: [])
        })
        if tools { model.deckTools = DeckTool.allCases }
        model.adopt(screen: screen)
        model.isExpanded = open
        return model
    }

    func testAtTheHoleTheBarDropsInsteadOfJoining() {
        let m = model()
        XCTAssertEqual(m.dropsFrom, HardwareNotch(width: 185, height: 32))
        XCTAssertNil(m.cutout, "nothing is joined")
        XCTAssertFalse(m.mergesWithCutout)
        XCTAssertNil(m.mergedScale, "the size setting stands; the hole does not shrink it")
        XCTAssertEqual(m.wings.count, 1, "one shape, not a pair either side of the hole")
    }

    func testTheBarIsCentredOnTheHoleAndSpansIt() {
        for (cells, tools) in [(1, false), (4, true), (6, true)] {
            let m = model(cells: cells, tools: tools)
            let wing = m.wings[0]
            let middle = m.panelSize.width / 2
            XCTAssertEqual(wing.lead + wing.length / 2, middle, accuracy: 0.5,
                           "\(cells) cells: centred on the panel, which is centred on the hole")
            let body = wing.length - 2 * m.flare * m.sizeScale
            XCTAssertGreaterThanOrEqual(body, 185, "\(cells) cells: the straight body spans the hole")
        }
    }

    func testEverythingIsDrawnBelowTheHole() {
        let m = model()
        XCTAssertEqual(m.dropInset * m.sizeScale, 32, accuracy: 0.001)
        XCTAssertEqual(m.notchDepth, NotchLayout.bodyDepth(for: .top) + m.dropInset, accuracy: 0.001,
                       "the shape is the hole's depth deeper")
        XCTAssertEqual(m.notchDrawnDepth, NotchLayout.bodyDepth(for: .top) * m.sizeScale + 32, accuracy: 0.001)
        XCTAssertGreaterThan(m.tooltipInset, 32 + NotchLayout.bodyDepth(for: .top) * m.sizeScale - 0.5,
                             "cards hang below the dropped bar")
    }

    func testAtRestOnlyTheHoleWakesIt() {
        let m = model(open: false)
        let rest = CursorGeometry(model: m, placement: m.placement).liveRect(gripRevealed: false)
        XCTAssertEqual(rest.width, 185, accuracy: 0.5)
        XCTAssertEqual(rest.height, 32, accuracy: 0.5, "no band past the hole, over the title bars below")
        XCTAssertEqual(rest.midX, m.panelSize.width / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(m.restingDepth * m.sizeScale, 32, "the folded pill hides inside the hole")
    }

    func testOpenTheWholeBarKeepsItOpen() {
        let m = model()
        let live = CursorGeometry(model: m, placement: m.placement).liveRect(gripRevealed: false)
        XCTAssertGreaterThanOrEqual(live.height, m.notchDrawnDepth - 0.5)
        XCTAssertGreaterThanOrEqual(live.width, m.wings[0].length - 0.5)
    }

    func testTheWindowFitsTheScreen() {
        let m = model(cells: 6, tools: true)
        XCTAssertLessThanOrEqual(m.panelSize.width, 1512, "the bar lies along the menu bar, not off its ends")
    }

    /// The hardware's notch is black, so the bar it grows into is drawn black
    /// whatever surface is chosen — glass would leave the hole a black block
    /// in it. The cards keep the chosen style.
    func testTheDroppedBarIsDrawnSolid() {
        let m = model()
        m.surfaceStyle = .glass
        XCTAssertEqual(m.drawnSurfaceStyle, .solid)
        XCTAssertEqual(m.cardSurfaceStyle, NotchSurfaceStyle.glass.effective)
        XCTAssertNotEqual(model(screen: Plain()).drawnSurfaceStyle, .solid,
                          "off the hole, the chosen style is drawn")
    }

    /// Reaching the notch opens it; only below the hole is a cell under the
    /// pointer, so arriving does not pop a card.
    func testTheHoleIsNoCellsHover() {
        let m = model()
        let g = CursorGeometry(model: m, placement: m.placement)
        let middle = m.panelSize.width / 2
        XCTAssertFalse(g.isBelowTheHole(CGPoint(x: middle, y: 10)))
        XCTAssertTrue(g.isBelowTheHole(CGPoint(x: middle, y: 60)))
        XCTAssertTrue(CursorGeometry(model: model(screen: Plain()), placement: m.placement)
            .isBelowTheHole(CGPoint(x: middle, y: 1)), "without a hole every point is fair")
    }

    func testBesideTheNotchIsStillTheJoin() {
        let m = model(style: .besideNotch)
        XCTAssertNil(m.dropsFrom)
        XCTAssertTrue(m.mergesWithCutout)
        XCTAssertEqual(m.wings.count, 2)
    }

    func testNoDropWithoutAHardwareNotchOrAwayFromTheTop() {
        XCTAssertNil(model(screen: Plain()).dropsFrom)
        XCTAssertNil(model(edge: .right).dropsFrom)
        XCTAssertEqual(model(screen: Plain()).dropInset, 0)
    }

    func testInTheHandItIsTheOrdinaryBar() {
        let m = model()
        m.holdsOffTheCutout = true
        m.adopt(screen: MacBook())
        XCTAssertNil(m.dropsFrom, "a held notch follows the pointer and drops again once let go")
    }
}
