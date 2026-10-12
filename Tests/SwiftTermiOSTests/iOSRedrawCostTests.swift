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
        /// A newline at the bottom of a scroll region the height of the alternate screen, which keeps no
        /// scrollback, as tmux scrolls a pane.
        case newlineInAFullScreenRegionOnTheAlternateScreen
        /// Lines printed over a status line at the bottom of the alternate screen, which is drawn again
        /// under them.
        case linesOverAStatusLineOnTheAlternateScreen
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
            switch self {
            case .newlineWithoutScrollback, .newlineInAFullScreenRegionOnTheAlternateScreen,
                 .linesOverAStatusLineOnTheAlternateScreen: 0
            case .newline, .regionAboveStatusLine, .regionBetweenFixedLines, .reverseIndex, .insertLine,
                 .deleteLine, .enterAlternateScreen, .leaveAlternateScreen: nil
            }
        }

        /// Output that sets up a screen of `rows` rows for the change.
        func setup(rows: Int) -> String {
            switch self {
            case .newlineInAFullScreenRegionOnTheAlternateScreen:
                Scrollback.alternateScreen.setup(rows: rows) + "\u{1b}[1;\(rows)r\u{1b}[\(rows)H"
            case .linesOverAStatusLineOnTheAlternateScreen:
                Scrollback.alternateScreen.setup(rows: rows) + "\r\nstatus 0"
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
            case .newline, .newlineWithoutScrollback, .newlineInAFullScreenRegionOnTheAlternateScreen: "\r\n"
            case .linesOverAStatusLineOnTheAlternateScreen: "\r\u{1b}[2Koutput 1\r\noutput 2\r\nstatus 1"
            case .regionAboveStatusLine, .regionBetweenFixedLines: "\u{1b}[\(rows - 1);1H\n"
            case .reverseIndex: "\u{1b}[H\u{1b}M"
            case .insertLine: "\u{1b}[3H\u{1b}[L"
            case .deleteLine: "\u{1b}[3H\u{1b}[M"
            case .enterAlternateScreen: "\u{1b}[?1049h\u{1b}[Halternate screen"
            case .leaveAlternateScreen: "\u{1b}[?1049l"
            }
        }
    }

    /// The scrollback a streaming test's terminal keeps.
    enum Scrollback: CaseIterable, Sendable {
        /// The default, still filling.
        case growing
        /// Full, so it drops its oldest line for each new one.
        case full
        /// None, as Lhûn's terminals keep, so each new line reuses the line that scrolled off the top.
        case absent
        /// The alternate screen, which never keeps scrollback, as tmux keeps the terminal on it, in a
        /// terminal that keeps none on its normal screen either.
        case alternateScreen

        var lines: Int? {
            switch self {
            case .growing: nil
            case .full: 3
            case .absent, .alternateScreen: 0
            }
        }

        /// Output that fills the screen the case streams into, a line of text in every row, and leaves the
        /// cursor at the end of the bottom row.
        func setup(rows: Int) -> String {
            switch self {
            case .growing, .full, .absent: ""
            case .alternateScreen:
                "\u{1b}[?1049h\u{1b}[H" + (1...rows).map { "alternate \($0)" }.joined(separator: "\r\n")
            }
        }
    }

    /// Output streaming lines past the bottom of the screen.
    enum LineStream: CaseIterable, Sendable {
        /// Lines, each ended with a newline, as a build log prints them.
        case lines
        /// The same inside a scroll region the height of the screen, as tmux sets one.
        case linesInAFullScreenRegion
        /// Lines printed over a status line at the bottom, which is erased first and drawn again under
        /// them, as a tool streams its log under its status.
        case linesOverAStatusLine

        /// Output that leaves the cursor on a blank bottom row, or on the status line.
        func setup(rows: Int) -> String {
            switch self {
            case .lines: "\r\n"
            case .linesInAFullScreenRegion: "\u{1b}[1;\(rows)r\u{1b}[\(rows)H\r\n"
            case .linesOverAStatusLine: "\r\nstatus 0"
            }
        }

        /// Output that prints `count` lines. It changes `count + 1` lines on screen: the lines printed, and
        /// the blank line under them or the status line drawn again.
        func output(printing count: Int) -> String {
            let printed = (1...count).map { "output \($0)\r\n" }.joined()
            switch self {
            case .lines, .linesInAFullScreenRegion: return printed
            case .linesOverAStatusLine: return "\r\u{1b}[2K" + printed + "status 1"
            }
        }

        /// How many of the lines `output(printing:)` changes hold text: the lines printed, and the status
        /// line drawn again, but not the blank line under printed lines.
        func linesWithText(printing count: Int) -> Int {
            switch self {
            case .lines, .linesInAFullScreenRegion: count
            case .linesOverAStatusLine: count + 1
            }
        }
    }

    /// A scrollback, and output streaming into it.
    struct StreamingCase: Sendable {
        var scrollback: Scrollback
        var stream: LineStream

        static let all = Scrollback.allCases.flatMap { scrollback in
            LineStream.allCases.map { StreamingCase(scrollback: scrollback, stream: $0) }
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
    /// What a frame did: how many rows it built anew, how many buffers it made for its rows' draw data,
    /// how many attributed strings it made of its rows' text, the vertex bytes it handed the GPU, and the
    /// pixels it drew, when its view's frames copy them out.
    struct DrawnFrame {
        var rowsRebuilt: Int
        var rowBuffersMade: Int
        var attributedStringsBuilt: Int
        var vertices: FrameVertexBytes
        var pixels: FramePixels? = nil
    }

    /// The pixels a frame drew, row by row and four bytes each.
    struct FramePixels: Equatable, CustomTestStringConvertible, CustomReflectable {
        var width: Int
        var bytes: [UInt8]

        var height: Int { bytes.count / (width * 4) }

        // A failure describes the frames and where they differ rather than printing every byte.
        var testDescription: String { "\(width)×\(height) pixels" }
        var customMirror: Mirror { Mirror(self, children: [:]) }

        /// How many pixels differ from the same pixels of `other`, and the runs of rows they are in.
        func difference(from other: FramePixels) -> String {
            guard width == other.width, bytes.count == other.bytes.count else {
                return "\(testDescription) against \(other.testDescription)"
            }
            var differingPixels = 0
            var rowRuns: [ClosedRange<Int>] = []
            for row in 0..<height {
                let rowStart = row * width * 4
                let differingInRow = stride(from: rowStart, to: rowStart + width * 4, by: 4).count(where: { pixel in
                    bytes[pixel..<pixel + 4] != other.bytes[pixel..<pixel + 4]
                })
                guard differingInRow > 0 else {
                    continue
                }
                differingPixels += differingInRow
                if let last = rowRuns.last, last.upperBound == row - 1 {
                    rowRuns[rowRuns.count - 1] = last.lowerBound...row
                } else {
                    rowRuns.append(row...row)
                }
            }
            let runs = rowRuns.map { "\($0.lowerBound)...\($0.upperBound)" }.joined(separator: ", ")
            return "\(differingPixels) pixels differ, in rows \(runs)"
        }
    }

    /// Has the frames `view` draws from here on copy out the pixels they draw. Call it before the view's
    /// first frame, so the view has made no framebuffer-only drawable.
    ///
    /// The view stops resizing its drawable on layout, leaving the size to the renderer, which sets it
    /// before each frame. When the view's height falls between device pixels, the two round it a pixel
    /// apart, and the frame after a layout would draw into a drawable a pixel taller than the frames
    /// around it.
    private func capturePixels(of view: TerminalView) throws {
        let metalView = try #require(view.metalView)
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
        try #require(view.metalRenderer).capturesPixelsForTesting = true
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
        // The count is shared by every view, so it starts from zero right before the frame, and every test
        // that draws runs on the main actor, so nothing else runs before the frame is counted.
        ViewLineSegment.debugAttributedStringsBuilt = 0
        try #require(view.metalView).draw()
        var frame = DrawnFrame(rowsRebuilt: renderer.debugRowsRebuilt,
                               rowBuffersMade: renderer.debugRowBuffersMade,
                               attributedStringsBuilt: ViewLineSegment.debugAttributedStringsBuilt,
                               vertices: renderer.lastFrameVertexBytesForTesting())
        try await waitUntil("the frame never finished on the GPU") { renderer.isIdle }
        if renderer.capturesPixelsForTesting {
            let pixels = try #require(renderer.lastFramePixelsForTesting(), "the frame copied out no pixels")
            frame.pixels = FramePixels(width: pixels.width, bytes: pixels.bytes)
        }
        return frame
    }

    /// Expects `frame` to draw the pixels `other` draws, and says where they differ when it does not.
    private func expectSamePixels(_ frame: DrawnFrame, _ other: DrawnFrame,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let pixels = try #require(frame.pixels, sourceLocation: sourceLocation)
        let otherPixels = try #require(other.pixels, sourceLocation: sourceLocation)
        #expect(pixels == otherPixels, "\(pixels.difference(from: otherPixels))", sourceLocation: sourceLocation)
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

    /// A glyph is rasterized once, a glyph with no ink such as a space included, and a font's name is
    /// copied out of it once. Building the same screen again, as a frame after the row cache is dropped
    /// does, rasterizes no glyph and copies no font name.
    @Test func rebuildingAScreenRasterizesNoGlyphAndCopiesNoFontName() async throws {
        let (view, window) = try makeFilledTerminal()
        let renderer = try #require(view.metalRenderer)
        _ = try await drawFrame(view)
        try #require(renderer.debugGlyphsRasterized > 0, "the first frame rasterized no glyph")
        try #require(renderer.debugFontNamesCopied > 0, "the first frame copied no font name")

        renderer.debugGlyphsRasterized = 0
        renderer.debugFontNamesCopied = 0
        _ = try await drawCachedThenRebuilt(view)
        #expect(renderer.debugGlyphsRasterized == 0)
        #expect(renderer.debugFontNamesCopied == 0)
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

    /// Streams `printedLines` lines past the bottom of a screen filled with text, and draws the frame due
    /// after them.
    private func drawFrameAfterStreaming(_ streaming: StreamingCase, printedLines: Int) async throws -> DrawnFrame {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5,
                                                    scrollback: streaming.scrollback.lines,
                                                    layout: Layout(height: .partialRow, aggregated: false))
        let rows = view.getTerminal().rows
        view.feed(text: streaming.scrollback.setup(rows: rows) + streaming.stream.setup(rows: rows))
        view.updateDisplay()
        _ = try await drawFrame(view)
        let buffer = view.getTerminal().displayBuffer
        let topLine = buffer.lines[try #require(view.metalVisibleRange()).lowerBound]

        view.feed(text: streaming.stream.output(printing: printedLines))
        view.updateDisplay()
        let topRow = try #require(view.metalVisibleRange()).lowerBound
        try #require(buffer.lines[topRow] !== topLine, "the output did not scroll the screen")
        let frame = try await drawFrame(view)
        withExtendedLifetime(window) {}
        return frame
    }

    /// Output streaming past the bottom of the screen, as a build log does, moves every line on the
    /// screen up a row for each line it prints. The frame after it builds the lines the output changed
    /// and keeps every other line's draw data, whatever scrollback the terminal keeps, on the alternate
    /// screen, inside a scroll region the height of the screen, and under a status line the output draws
    /// again.
    @Test(arguments: StreamingCase.all, [1, 3])
    func streamingOutputBuildsOnlyTheLinesItChanges(_ streaming: StreamingCase, printedLines: Int) async throws {
        let frame = try await drawFrameAfterStreaming(streaming, printedLines: printedLines)
        #expect(frame.rowsRebuilt == printedLines + 1)
    }

    /// A line that streaming output only moved up the screen draws from the buffers it had, wherever it
    /// moved to, so the frame after the output makes buffers for the lines it changed alone: one for the
    /// glyphs of each line that holds text, and none for a blank line.
    @Test(arguments: StreamingCase.all, [1, 3])
    func streamingOutputMakesBuffersOnlyForTheLinesItChanges(_ streaming: StreamingCase,
                                                             printedLines: Int) async throws {
        let frame = try await drawFrameAfterStreaming(streaming, printedLines: printedLines)
        #expect(frame.rowBuffersMade == streaming.stream.linesWithText(printing: printedLines))
    }

    /// The frame after streaming output shapes the lines the output changed straight from the text and
    /// attributes the line walk gathers, making no attributed string of them to take apart again.
    @Test(arguments: StreamingCase.all, [1, 3])
    func streamingOutputBuildsNoAttributedString(_ streaming: StreamingCase, printedLines: Int) async throws {
        let frame = try await drawFrameAfterStreaming(streaming, printedLines: printedLines)
        #expect(frame.attributedStringsBuilt == 0)
    }

    /// A frame that draws lines from the draw data the renderer kept hands the GPU the bytes the same
    /// frame built from scratch hands it, and draws the same pixels.
    @Test(arguments: ScreenChange.allCases, Layout.all)
    func keptRowsDrawWhatRebuiltRowsDraw(after change: ScreenChange, layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: change.scrollback,
                                                    layout: layout)
        try capturePixels(of: view)
        let rows = view.getTerminal().rows
        view.feed(text: change.setup(rows: rows))
        view.updateDisplay()
        _ = try await drawFrame(view)

        view.feed(text: change.output(rows: rows))
        view.updateDisplay()
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        try expectSamePixels(cached, rebuilt)
        withExtendedLifetime(window) {}
    }

    /// A frame that keeps buffers for each row has the GPU draw a row's buffers up the view at the row its
    /// line moved to, where a frame that gathers its rows into one set of buffers moves their draw data
    /// itself. After a change that moves lines, the two draw the same pixels.
    @Test(arguments: ScreenChange.allCases, Layout.Height.allCases)
    func keptRowBuffersDrawWhereGatheredRowsDraw(after change: ScreenChange, height: Layout.Height) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: change.scrollback,
                                                    layout: Layout(height: height, aggregated: false))
        try capturePixels(of: view)
        let rows = view.getTerminal().rows
        view.feed(text: change.setup(rows: rows))
        view.updateDisplay()
        _ = try await drawFrame(view)

        view.feed(text: change.output(rows: rows))
        view.updateDisplay()
        let kept = try await drawFrame(view)
        view.metalBufferingMode = .perFrameAggregated
        let gathered = try await drawFrame(view)
        try expectSamePixels(kept, gathered)
        withExtendedLifetime(window) {}
    }

    /// The selection is drawn by buffer row, not with its line. A selection made as output scrolls the
    /// screen draws where a frame built from scratch draws it.
    @Test(arguments: Layout.all)
    func aSelectionMadeAsTheScreenScrollsDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, layout: layout)
        try capturePixels(of: view)
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
        try expectSamePixels(cached, rebuilt)
        withExtendedLifetime(window) {}
    }

    /// Output drops the selection, and the view marks the selection's rows on a later turn of the main
    /// loop. A frame drawn before then, after the output scrolled the screen, draws no selection, as a
    /// frame built from scratch draws none.
    @Test(arguments: Layout.all)
    func aScrollThatDropsTheSelectionDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, layout: layout)
        try capturePixels(of: view)
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
        try expectSamePixels(cached, rebuilt)
        withExtendedLifetime(window) {}
    }

    /// A hovered link is drawn by buffer row. Output that scrolls a full scrollback moves every line up a
    /// buffer row under the link, and the frame after it draws the link where a frame built from scratch
    /// draws it.
    @Test(arguments: Layout.all)
    func aScrollUnderAHoveredLinkDrawsWhatARebuildDraws(layout: Layout) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: 3, layout: layout)
        try capturePixels(of: view)
        let linkRow = try #require(view.metalVisibleRange()).lowerBound + 3
        view.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: linkRow, range: 0..<4)]
        view.getTerminal().updateFullScreen()
        view.updateDisplay()
        _ = try await drawFrame(view)

        view.feed(text: "\r\n")
        view.updateDisplay()
        let (cached, rebuilt) = try await drawCachedThenRebuilt(view)
        #expect(cached.vertices.rows == rebuilt.vertices.rows)
        try expectSamePixels(cached, rebuilt)
        withExtendedLifetime(window) {}
    }

    /// The blink timer hides blinking text and marks the rows it is on. Output that scrolls a full
    /// scrollback, or the alternate screen, which keeps none, before the next frame moves the line up a
    /// buffer row, off the row marked for it, and that frame draws the text hidden, as a frame built from
    /// scratch draws it.
    @Test(arguments: Layout.all, [Scrollback.full, .alternateScreen])
    func aBlinkMarkedBeforeAScrollDrawsWhatARebuildDraws(layout: Layout, scrollback: Scrollback) async throws {
        let (view, window) = try makeFilledTerminal(linesPastTheScreen: 5, scrollback: scrollback.lines,
                                                    layout: layout)
        try capturePixels(of: view)
        view.feed(text: scrollback.setup(rows: view.getTerminal().rows) + "\r\u{1b}[5mblink\u{1b}[25m")
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
        try expectSamePixels(cached, rebuilt)
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

    @Test(.enabled {
        await MainActor.run { !UIAccessibility.isVoiceOverRunning && !UIAccessibility.isSwitchControlRunning }
    })
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
