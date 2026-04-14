import AppKit

/// Borderless non-activating panel that can still become key
/// (so hosted text fields accept input without activating the whole app).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
