import AppKit
import Foundation

@MainActor
final class PowerUserDiagnosticsStore: ObservableObject {
    struct FeatureState: Identifiable, Equatable {
        let id: String
        let title: String
        let isEnabled: Bool
    }

    struct Snapshot: Equatable {
        let helperConnectionStatus: String
        let activeReservationStrategy: String
        let activeWindowConstrainer: String
        let displayMetrics: DisplayMetricsSnapshot?
        let prerequisites: [PowerUserPrerequisite]
        let featureStates: [FeatureState]
        let lastBridgeError: String?

        static let empty = Snapshot(
            helperConnectionStatus: "Unavailable",
            activeReservationStrategy: "OverlayReservationStrategy",
            activeWindowConstrainer: "AXWindowConstrainer",
            displayMetrics: nil,
            prerequisites: [],
            featureStates: [],
            lastBridgeError: nil
        )
    }

    @Published private(set) var snapshot: Snapshot = .empty

    private let bridge: any PowerUserBridge
    private let availability: any PrivateFeatureAvailability
    private let reservationStrategy: any DesktopReservationStrategy
    private let windowConstrainer: any WindowConstraining
    private let featureFlags: PowerUserFeatureFlags
    private let barWindowProvider: () -> NSWindow?
    private var timer: Timer?

    init(
        bridge: any PowerUserBridge,
        availability: any PrivateFeatureAvailability,
        reservationStrategy: any DesktopReservationStrategy,
        windowConstrainer: any WindowConstraining,
        featureFlags: PowerUserFeatureFlags,
        barWindowProvider: @escaping () -> NSWindow?
    ) {
        self.bridge = bridge
        self.availability = availability
        self.reservationStrategy = reservationStrategy
        self.windowConstrainer = windowConstrainer
        self.featureFlags = featureFlags
        self.barWindowProvider = barWindowProvider

        refresh()
        if AppFlavor.current.isPowerUser {
            startRefreshing()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        bridge.connectIfNeeded()
        snapshot = Snapshot(
            helperConnectionStatus: bridge.connectionStatus,
            activeReservationStrategy: reservationStrategy.diagnosticsName,
            activeWindowConstrainer: windowConstrainer.diagnosticsName,
            displayMetrics: windowConstrainer.metrics(for: barWindowProvider()),
            prerequisites: availability.prerequisites(),
            featureStates: PowerUserFeatureFlag.allCases.map {
                FeatureState(id: $0.rawValue, title: $0.title, isEnabled: featureFlags.isEnabled($0))
            },
            lastBridgeError: bridge.lastErrorDescription
        )
    }

    private func startRefreshing() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
