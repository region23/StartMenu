import AppKit
import SwiftUI

/// Provides a stable default cursor for borderless SwiftUI-hosted windows.
/// Nested controls can still register their own cursor rects (for example,
/// the search field can continue using I-beam).
final class CursorHostingView<Content: View>: NSHostingView<Content> {
    private var lastCursorRectSize: CGSize = .zero

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        super.resetCursorRects()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastCursorRectSize else { return }
        lastCursorRectSize = size
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastCursorRectSize = bounds.size
        window?.invalidateCursorRects(for: self)
    }
}
