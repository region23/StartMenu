import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissionsService: PermissionsService
    let onDismiss: () -> Void

    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to Start Menu")
                .font(.title2).bold()
            Text("Grant Accessibility so Start Menu can enumerate, focus, close, and minimize windows of other apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Accessibility",
                subtitle: "Required to focus, raise, and manage windows.",
                granted: permissionsService.hasAccessibility,
                primaryAction: ("Request", { permissionsService.requestAccessibility() }),
                secondaryAction: ("Open Settings", { permissionsService.openAccessibilitySettings() })
            )

            Spacer()

            HStack {
                Spacer()
                Button("Recheck") { permissionsService.refresh() }
                    .keyboardShortcut("r")
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissionsService.hasAccessibility)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    permissionsService.refresh()
                    if permissionsService.hasAccessibility {
                        onDismiss()
                    }
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let granted: Bool
    let primaryAction: (LocalizedStringKey, () -> Void)
    let secondaryAction: (LocalizedStringKey, () -> Void)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack(spacing: 8) {
                        Button(primaryAction.0) { primaryAction.1() }
                        Button(secondaryAction.0) { secondaryAction.1() }
                            .buttonStyle(.link)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(permissionsService: PermissionsService(), onDismiss: {})
    }
}
#endif
