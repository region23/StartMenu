import Foundation
import ServiceManagement

@MainActor
final class AutostartService: ObservableObject {
    @Published private(set) var isEnabled: Bool = false

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            // Registration can fail if the user previously denied in Login Items;
            // refresh so the toggle reflects the actual system state.
        }
        refresh()
    }
}
