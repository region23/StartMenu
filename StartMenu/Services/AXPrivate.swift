import ApplicationServices
import CoreGraphics

// Private API: maps an AXUIElement back to its CGWindowID. Used across the
// app (window lookup and enumerating minimized windows). Widely used by
// third-party window managers such as Yabai and Rectangle. Not available
// in App Store sandboxed apps.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
