#if os(iOS)
import Metal
import Testing
import UIKit

@testable import SwiftTerm

/// What a screen update costs a Metal terminal on iPad and iPhone, counted rather than timed.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct iOSRedrawCostTests {
    /// A terminal drawing with Metal in a window, every row of its screen holding text.
    private func makeFilledTerminal() throws -> (TerminalView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let view = TerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.textBlinkApplicationActive = true
        try view.setUseMetal(true)
        let rows = view.getTerminal().rows
        view.feed(text: (1...rows).map { "line \($0)" }.joined(separator: "\r\n"))
        view.updateDisplay()
        return (view, window)
    }

#if DEBUG
    /// Draws a frame now and returns how many rows it built anew, once the GPU has finished it so the
    /// next draw is not turned away.
    private func drawFrame(_ view: TerminalView) async throws -> Int {
        let renderer = try #require(view.metalRenderer)
        try #require(renderer.isIdle, "a frame is still on the GPU")
        try #require(view.metalView).draw()
        let rebuilt = renderer.debugRowsRebuilt
        let deadline = Date().addingTimeInterval(5)
        while !renderer.isIdle {
            try #require(Date() < deadline, "the frame never finished on the GPU")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return rebuilt
    }

    @Test func oneRowUpdateRebuildsOnlyThatRow() async throws {
        let (view, window) = try makeFilledTerminal()
        let firstFrame = try await drawFrame(view)
        #expect(firstFrame == view.getTerminal().rows)

        // An agent's spinner redraws its own line in place, many times a second.
        view.feed(text: "\r⠙ working")
        view.updateDisplay()
        let spinnerFrame = try await drawFrame(view)
        #expect(spinnerFrame == 1)
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
        #expect(blinkFrame == 1)
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
}
#endif
