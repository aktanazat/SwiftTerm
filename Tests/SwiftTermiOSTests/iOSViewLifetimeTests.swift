#if os(iOS)
import Metal
import Testing
import UIKit

@testable import SwiftTerm

/// What keeps a terminal view alive on iPad and iPhone.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct iOSViewLifetimeTests {
    /// The display link that runs the view's screen updates stays in the run loop until the view goes,
    /// so it must not be what keeps the view, its terminal and its renderer alive. Work the view queued
    /// on the main queue holds it only until that work runs.
    @Test func aTerminalNothingHoldsGoesAway() async throws {
        weak var released: TerminalView?
        try autoreleasepool {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let view = TerminalView(frame: window.bounds)
            window.addSubview(view)
            try view.setUseMetal(true)
            view.feed(text: "hello")
            view.updateDisplay()
            view.removeFromSuperview()
            released = view
        }
        for _ in 1...10 where released != nil {
            await mainQueueTurn()
        }
        #expect(released == nil)
    }

    /// Returns once the main queue has run everything queued on it before this call.
    private func mainQueueTurn() async {
        await withCheckedContinuation { turned in
            DispatchQueue.main.async { turned.resume() }
        }
    }
}
#endif
