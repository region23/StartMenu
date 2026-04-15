import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private let window: NSWindow

    init(permissionsService: PermissionsService) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Start Menu — Setup")
        window.center()
        window.isReleasedWhenClosed = false

        let ref = WeakRef()
        let hosting = NSHostingView(rootView: OnboardingView(
            permissionsService: permissionsService,
            onDismiss: { ref.value?.close() }
        ))
        window.contentView = hosting
        ref.value = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }

    private final class WeakRef {
        weak var value: OnboardingWindowController?
    }
}
