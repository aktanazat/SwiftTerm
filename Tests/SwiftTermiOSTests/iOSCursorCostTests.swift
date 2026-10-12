#if os(iOS)
import Metal
import Testing
import UIKit

@testable import SwiftTerm

/// What showing and hiding the cursor costs a terminal drawing with Metal, counted rather than timed.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct iOSCursorCostTests {
    /// A terminal view that counts the subviews added to it and taken from it.
    final class CountingTerminalView: TerminalView {
        var subviewChanges = 0

        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            subviewChanges += 1
        }

        override func willRemoveSubview(_ subview: UIView) {
            super.willRemoveSubview(subview)
            subviewChanges += 1
        }
    }

    /// tmux hides the cursor while it writes an update and shows it again after, so a streaming build log
    /// hides and shows it with every update. With Metal the renderer draws the cursor, and taking the caret
    /// view out of the view tree and putting it back each time had UIKit lay the terminal out again, 40
    /// times a second.
    @Test func cursorHiddenAroundEachUpdateLeavesTheViewTreeAlone() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let view = CountingTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.textBlinkApplicationActive = true
        try view.setUseMetal(true)
        view.feed(text: "ready")
        view.updateDisplay()
        view.subviewChanges = 0

        for update in 1...20 {
            view.feed(text: "\u{1b}[?25l\r\nline \(update)\u{1b}[?25h")
            view.updateDisplay()
        }

        #expect(view.subviewChanges == 0)
        #expect(!view.getTerminal().cursorHidden)
    }
}
#endif
