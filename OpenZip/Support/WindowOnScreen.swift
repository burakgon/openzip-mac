import AppKit
import SwiftUI

/// Keeps a window that grows with what is in it on the screen.
///
/// A window that follows the size of its content grows downwards, and stays where it is
/// while it does: near the bottom of the screen its lower edge, with the buttons on it,
/// ends up behind the Dock or below the screen. With this in its background the window
/// moves up by as much as it takes.
struct KeepsWindowOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
        }

        @objc private func windowResized() {
            // Not while the user is the one who sizes it: then it is theirs to place.
            guard let window, !window.inLiveResize, let visible = window.screen?.visibleFrame else { return }
            let frame = window.frame
            guard frame.minY < visible.minY else { return }
            // Up to the bottom of what the screen shows, but never with the title bar
            // above its top: a window taller than the screen keeps its head in view.
            window.setFrameOrigin(NSPoint(x: frame.minX, y: min(visible.minY, visible.maxY - frame.height)))
        }
    }
}
