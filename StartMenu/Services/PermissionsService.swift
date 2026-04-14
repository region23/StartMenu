import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class PermissionsService: ObservableObject {
    @Published private(set) var hasAccessibility: Bool = false
    @Published private(set) var hasScreenRecording: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecording = Self.detectScreenRecording()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestScreenRecording() {
        Task {
            _ = try? await SCShareableContent.current
            await MainActor.run { self.refresh() }
        }
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func detectScreenRecording() -> Bool {
        // CGPreflightScreenCaptureAccess is the sanctioned probe; it does not prompt.
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }
}
