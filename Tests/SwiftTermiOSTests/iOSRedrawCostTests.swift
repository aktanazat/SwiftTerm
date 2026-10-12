#if os(iOS)
import Metal
import Testing
import UIKit

@testable import SwiftTerm

/// What a screen update costs a Metal terminal on iPad and iPhone, counted rather than timed.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct iOSRedrawCostTests {
    /// How a test's view fits its rows and hands their draw data to the GPU.
    struct Layout: Sendable {
        enum Height: CaseIterable, Sendable {
            /// The view fits its rows exactly.
            case wholeRows
            /// The view shows half of one more row, as a view sized by its window usually does.
            case partialRow
            /// The same and a quarter point more, which puts the edges of the rows between device pixels
            /// on 2x and 3x screens.
            case partialRowBetweenPixels
        }

        var height: Height
        /// Whether the renderer gathers every row's draw data into one set of buffers a frame, rather
        /// than keeping buffers for each row.
        var aggregated: Bool

        static let all = Height.allCases.flatMap { height in
            [false, true].map { Layout(height: height, aggregated: $0) }
        }
    }

    /// Output that moves, replaces, or restyles the lines of a screen that has scrolled past its first
    /// page.
    enum ScreenChange: CaseIterable, Sendable {
        /// A newline at the bottom scrolls the screen up, and a blank line comes in under it.
        case newline
        /// The same with no scrollback, so the top line is cleared and comes back in at the bottom.
        case newlineWithoutScrollback
        /// A newline at the bottom of a scroll region above a status line, as tmux scrolls.
        case regionAboveStatusLine
        /// A newline at the bottom of a scroll region between fixed lines, as vim scrolls.
        case regionBetweenFixedLines
        /// A reverse index at the top of the screen scrolls it down.
        case reverseIndex
        /// Inserting a line pushes the lines under it down.
        case insertLine
        /// Deleting a line pulls the lines under it up.
        case deleteLine
        case enterAlternateScreen
        case leaveAlternateScreen

        /// The scrollback the terminal keeps, or nil for the default.
        var scrollback: Int? {
            self == .newlineWithoutScrollback ? 0 : nil
        }

        /// Output that sets up a screen of `rows` rows for the change.
        func setup(rows: Int) -> String {
            switch self {
            case .regionAboveStatusLine: "\u{1b}[1;\(rows - 1)r"
            case .regionBetweenFixedLines: "\u{1b}[2;\(rows - 1)r"
            case .leaveAlternateScreen: "\u{1b}[?1049h\u{1b}[Halternate screen"
            case .newline, .newlineWithoutScrollback, .reverseIndex, .insertLine, .deleteLine,
                 .enterAlternateScreen: ""
            }
        }

        /// The output that makes the change on a screen of `rows` rows.
        func output(rows: Int) -> String {
            switch self {
            case .newline, .newlineWithoutScrollback: "\r\n"
            case .regionAboveStatusLine, .regionBetweenFixedLines: "\u{1b}[\(rows - 1);1H\n"
            case .reverseIndex: "\u{1b}[H\u{1b}M"
            case .insertLine: "\u{1b}[3H\u{1b}[L"
            case .deleteLine: "\u{1b}[3H\u{1b}[M"
            case .enterAlternateScreen: "\u{1b}[?1049h\u{1b}[Halternate screen"
            case .leaveAlternateScreen: "\u{1b}[?1049l"
            }
        }
    }

    /// A terminal drawing with Metal in a window, every row of its screen holding text, and
    /// `linesPastTheScreen` more lines scrolled up past the top of the screen.
    private func makeFilledTerminal(linesPastTheScreen: Int = 0,
                                    scrollback: Int? = nil,
                                    layout: Layout = Layout(height: .wholeRows, aggregated: false))
        throws -> (TerminalView, UIWindow) {
        let cellHeight = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480)).cellDimension.height
        let wholeRows = (480 / cellHeight).rounded(.down)
        let height: CGFloat = switch layout.height {
        case .wholeRows: wholeRows * cellHeight
        case .partialRow: (wholeRows + 0.5) * cellHeight
        case .partialRowBetweenPixels: (wholeRows + 0.5) * cellHeight + 0.25
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: height))
        let view = TerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.textBlinkApplicationActive = true
        view.metalBufferingMode = layout.aggregated ? .perFrameAggregated : .perRowPersistent
        if let scrollback {
            view.changeScrollback(scrollback)
        }
        try view.setUseMetal(true)
        let rows = view.getTerminal().rows
        view.feed(text: (1...rows + linesPastTheScreen).map { "line \($0)" }.joined(separator: "\r\n"))
        view.updateDisplay()
        return (view, window)
    }

#if DEBUG
    /// What a frame did: how many rows it built anew, and the vertex bytes it handed the GPU.
    struct DrawnFrame {
        var rowsRebuilt: Int
        var vertices: FrameVertexBytes
    }

    /// Waits until `condition` holds, failing the test after five seconds.
    private func waitUntil(_ failure: Comment, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            try #require(Date() < deadline, failure)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Draws a frame once the GPU has finished any earlier one, so the draw is not turned away, and waits
    /// for the GPU to finish it.
    private func drawFrame(_ view: TerminalView) async throws -> DrawnFrame {
        let renderer = try #require(view.metalRenderer)
        try await waitUntil("an earlier frame never finished on the GPU") { renderer.isIdle }
        try #require(view.metalView).draw()
        let frame = DrawnFrame(rowsRebuilt: renderer.debugRowsRebuilt,
                               vertices: renderer.lastFrameVertexBytesForTesting())
        try await waitUntil("the frame never finished on the GPU") { renderer.isIdle }
        return frame
    }

    /// Draws the frame due after a change from whatever draw data the renderer kept, then the same frame
    /// with every row built from scratch.
    private func drawCachedThenRebuilt(_ view: TerminalView) async throws -> (cached: DrawnFrame, rebuilt: DrawnFrame) {
        let cached = try await drawFrame(view)
        try #require(view.metalRenderer).discardRowCacheForTesting()
        let rebuilt = try await drawFrame(view)
        try #require(rebuilt.rowsRebuilt == view.metalVisibleRange()?.count,
                     "the second frame did not build every row it drew")
        return (cached, rebuilt)
    }

    @Test func oneRowUpdateRebuildsOnlyThatRow() async throws {
        let (view, window) = try makeFilledTerminal()
        let firstFrame = try await drawFrame(view)
        #expect(firstFrame.rowsRebuilt == view.getTerminal().rows)

        // An agent's spinner redraws its own line in place, many times a second.
        view.feed(text: "\r⠙ working")
        view.updateDisplay()
        let spinnerFrame = try await drawFrame(view)
        #expect(spinnerFrame.rowsRebuilt == 1)
        withExtendedLifetime(window) {}
    }

    /// Blinking changes how a row draws without changing its text, so only the row marked for it shows it.
    @Test func blinkRedrawsTheBlinkingRowAlone() async throws {
        let (view, window) = try makeFilledTerminal()
        let lastRow = view.getTerminal().rows - 1
        view.feed(text: "\r\u{1b}[5mblink\u{1b}[25m")
        view.updateDisplay()
        _ = try await drawFrame(view)

        // What the blink timer does: hide the blinking text and mark its rows, then update.
        view.setTextBlinkVisibleForTesting(false)
        view.updateDisplay(notifyAccessibility: false)
        #expect(view.metalDirtyRange == lastRow...lastRow)
        let blinkFrame = try await drawFrame(view)
        #expect(blinkFrame.rowsRebuilt == 1)
        withExtendedLifetime(window) {}
    }

    /// Output streaming past the bottom of the screen, as a build log does, moves every line on the
    /// screen up a row for each line it prints. The frame after it builds the lines printed and the blank
    /// line under them, and keeps every other line's draw data, whether the scrollback still grows or is
    /// full and drops its oldest line for each new one.
    @Test(arguments: [false, true], [1, 3])
    func streamingOutputBuildsOnlyTheLinesItPrints(scrollbackFull: Bool, printedLines: Int) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5,
                                                    scrollback: scrollbackFull ? 3 : nil,
                                                    layout: Layout(height: .partialRow, aggregated: false))
        view.feed(text: "\r\n")
        view.updateDisplay()
        _ = try await drawFrame(view)
        let buffer = view.getTerminal().displayBuffer
        let topLine = buffer.lines[try #require(view.metalVisibleRange()).lowerBound]

        view.feed(text: (1...printedLines).map { "output \($0)\r\n" }.joined())
        view.updateDisplay()
        let topRow = try #require(view.metalVisibleRange()).lowerBound
        try #require(buffer.lines[topRow] !== topLine, "the output did not scroll the screen")
        let frame = try await drawFrame(view)
        #expect(frame.rowsRebuilt == printedLines + 1)
        withExtendedLifetime(window) {}
    }

    /// A frame that draws lines from the draw data the renderer kept hands the GPU the bytes the same
    /// frame built from scratch hands it.
    @Test(arguments: ScreenChange.allCases, Layout.all)
    func keptRowsDrawWhatRebuiltRowsDraw(after change: ScreenChange, layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: change.scrollback,
                                                    layout: layout)
        let rows = view.getTerminal().rows
        view.feed(text: change.setup(rows: rows))
        view.updateDisplay()
        _ = try await drawFrame(view)

        view.feed(text: change.output(rows: rows))
        view.updateDisplay()
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        withExtendedLifetime(window) {}
    }

    /// The selection is drawn by buffer row, not with its line. A selection made as output scrolls the
    /// screen draws where a frame built from scratch draws it.
    @Test(arguments: Layout.all)
    func aSelectionMadeAsTheScreenScrollsDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, layout: layout)
        let lastRow = try #require(view.metalVisibleRange()).upperBound
        view.selection.select(row: lastRow - 5)
        try await waitUntil("the view never marked the selection's rows") { !view.pendingSelectionChanged }
        _ = try await drawFrame(view)

        // Output drops the selection, so this one is new.
        view.feed(text: "\r\n")
        view.selection.select(row: lastRow - 2)
        view.updateDisplay()
        try await waitUntil("the view never marked the selection's rows") { !view.pendingSelectionChanged }
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        withExtendedLifetime(window) {}
    }

    /// Output drops the selection, and the view marks the selection's rows on a later turn of the main
    /// loop. A frame drawn before then, after the output scrolled the screen, draws no selection, as a
    /// frame built from scratch draws none.
    @Test(arguments: Layout.all)
    func aScrollThatDropsTheSelectionDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, layout: layout)
        let lastRow = try #require(view.metalVisibleRange()).upperBound
        view.selection.setSelection(start: Position(col: 0, row: lastRow - 5),
                                    end: Position(col: 3, row: lastRow - 3))
        try await waitUntil("the view never marked the selection's rows") { !view.pendingSelectionChanged }
        _ = try await drawFrame(view)

        view.feed(text: "\r\n")
        view.updateDisplay()
        try #require(!view.selection.active, "the output did not drop the selection")
        try #require(view.pendingSelectionChanged, "the view marked the selection's rows before the frame")
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        withExtendedLifetime(window) {}
    }

    /// A hovered link is drawn by buffer row. Output that scrolls a full scrollback moves every line up a
    /// buffer row under the link, and the frame after it draws the link where a frame built from scratch
    /// draws it.
    @Test(arguments: Layout.all)
    func aScrollUnderAHoveredLinkDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: 3, layout: layout)
        let linkRow = try #require(view.metalVisibleRange()).lowerBound + 3
        view.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: linkRow, range: 0..<4)]
        view.getTerminal().updateFullScreen()
        view.updateDisplay()
        _ = try await drawFrame(view)

        view.feed(text: "\r\n")
        view.updateDisplay()
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        withExtendedLifetime(window) {}
    }

    /// The blink timer hides blinking text and marks the rows it is on. Output that scrolls a full
    /// scrollback before the next frame moves the line up a buffer row, off the row marked for it, and
    /// that frame draws the text hidden, as a frame built from scratch draws it.
    @Test(arguments: Layout.all)
    func aBlinkMarkedBeforeAScrollDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: 3, layout: layout)
        view.feed(text: "\r\u{1b}[5mblink\u{1b}[25m")
        view.updateDisplay()
        // Stop the view's blink timer, and keep the view from starting another, so only the test shows
        // and hides the text.
        let blinkTimer = try #require(view.textBlinkTimer, "the view started no blink timer")
        blinkTimer.invalidate()
        _ = try await drawFrame(view)

        view.setTextBlinkVisibleForTesting(false)
        view.textBlinkTimer = blinkTimer
        view.feed(text: "\r\n")
        view.updateDisplay()
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        withExtendedLifetime(window) {}
    }

    /// A blinking cursor shows and hides about once a second with nothing else on the screen changing,
    /// so a frame that only hides it builds no row and draws every row as the frame before it did.
    @Test(arguments: Layout.all)
    func aCursorBlinkBuildsNoRow(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, layout: layout)
        view.caretViewTracksFocus = false
        let renderer = try #require(view.metalRenderer)
        renderer.setCursorBlinkOnForTesting(true)
        let shown = try await drawFrame(view)
        try #require(!shown.vertices.cursor.joined().isEmpty, "the frame drew no cursor")

        renderer.setCursorBlinkOnForTesting(false)
        let hidden = try await drawFrame(view)
        try #require(hidden.vertices.cursor.joined().isEmpty, "the frame drew the hidden cursor")
        #expect(hidden.rowsRebuilt == 0)
        #expect(hidden.vertices.rows == shown.vertices.rows)
        withExtendedLifetime(window) {}
    }
#endif

    /// Counts the layout notices the view would post, instead of posting them.
    private final class NoticeCountingTerminalView: TerminalView {
        var layoutNotices = 0
        override func postAccessibilityLayoutChanged() {
            layoutNotices += 1
        }
    }

    @Test(.enabled(if: !UIAccessibility.isVoiceOverRunning && !UIAccessibility.isSwitchControlRunning))
    func updatesPostNoLayoutNoticeWithoutVoiceOverOrSwitchControl() {
        let view = NoticeCountingTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        for step in 1...5 {
            view.feed(text: "\rstep \(step)")
            view.updateDisplay()
        }
        #expect(view.layoutNotices == 0)
    }

    @Test func aTerminalHoldsAtMostTwoDrawables() throws {
        let (view, window) = try makeFilledTerminal()
        let metalView = try #require(view.metalView)
        metalView.drawableSize = CGSize(width: 64, height: 64)
        let layer = try #require(metalView.layer as? CAMetalLayer)
        let first = layer.nextDrawable()
        let second = layer.nextDrawable()
        #expect(first != nil)
        #expect(second != nil)
        #expect(layer.maximumDrawableCount == 2)
#if !targetEnvironment(simulator)
        // With both held, a third would be one more texture the size of the view: the layer waits a
        // second for one to come back, then gives up. The simulator hands out more than its layer allows.
        #expect(layer.nextDrawable() == nil)
#endif
        withExtendedLifetime((first, second, window)) {}
    }

    /// Counts the times the view starts its display link.
    private final class LinkCountingTerminalView: TerminalView {
        var linkStarts = 0
        override func startDisplayUpdates() {
            linkStarts += 1
            super.startDisplayUpdates()
        }
    }

    @Test func mainThreadFeedsLeaveTheDisplayLinkStopped() {
        let view = LinkCountingTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        for chunk in 1...5 {
            view.feed(text: "\rchunk \(chunk)")
        }
        #expect(view.linkStarts == 0)
        #expect(view.link.isPaused)
    }

    @Test func aFeedOnAnotherThreadRunsTheDisplayLinkUntilItEnds() {
        let view = LinkCountingTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let fed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            view.feed(text: "\rchunk")
            fed.signal()
        }
        fed.wait()
        #expect(view.linkStarts == 1)
        #expect(view.link.isPaused)
    }
}
#endif
