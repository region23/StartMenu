import AppKit
import SwiftUI

/// Provides a stable default cursor for borderless SwiftUI-hosted windows.
/// Nested controls can still register their own cursor rects (for example,
/// the search field can continue using I-beam).
final class CursorHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        super.resetCursorRects()
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}
