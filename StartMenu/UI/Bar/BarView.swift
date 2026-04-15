import AppKit
import SwiftUI

struct BarView: View {
    @ObservedObject var windowService: WindowService
    @ObservedObject var settingsStore: SettingsStore
    let windowController: WindowController
    let onStartButtonFrame: (NSRect) -> Void
    let onStartButtonTap: () -> Void

    private var scale: Double { settingsStore.uiScale }

    var body: some View {
        HStack(spacing: 8 * scale) {
            StartButton(scale: scale, onTap: onStartButtonTap, onFrame: onStartButtonFrame)
            Divider().frame(height: 28 * scale).opacity(0.25)
            WindowChipsList(
                groups: WindowGroup.group(windowService.windows),
                activePID: windowService.activeAppPID,
                scale: scale,
                onTap: { windowController.activate($0) },
                onClose: { windowController.close($0) },
                onMinimize: { windowController.minimize($0) }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.15))
        )
    }
}

private struct StartButton: View {
    let scale: Double
    let onTap: () -> Void
    let onFrame: (NSRect) -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48 * scale, height: 36 * scale)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(WindowFrameReader { frame in onFrame(frame) })
    }
}

private struct WindowChipsList: View {
    let groups: [WindowGroup]
    let activePID: pid_t?
    let scale: Double
    let onTap: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onMinimize: (WindowInfo) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8 * scale) {
                ForEach(groups) { group in
                    WindowChipView(
                        group: group,
                        isActive: group.id == activePID,
                        scale: scale
                    )
                    .onTapGesture { onTap(group.representative) }
                    .contextMenu {
                        if group.windows.count > 1 {
                            ForEach(group.windows) { win in
                                Button(win.displayTitle) { onTap(win) }
                            }
                            Divider()
                        }
                        Button("Minimize") { onMinimize(group.representative) }
                        Button("Close") { onClose(group.representative) }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct WindowChipView: View {
    let group: WindowGroup
    let isActive: Bool
    let scale: Double
    @State private var hovering = false

    private var representative: WindowInfo { group.representative }
    private var dimmed: Bool { group.isAllMinimized }

    var body: some View {
        HStack(spacing: 6 * scale) {
            if let icon = AppIconService.shared.icon(forPID: representative.ownerPID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20 * scale, height: 20 * scale)
                    .opacity(dimmed ? 0.55 : 1.0)
            }
            Text(representative.displayTitle)
                .font(.system(size: 12 * scale))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170 * scale, alignment: .leading)
                .opacity(dimmed ? 0.6 : 1.0)
                .italic(dimmed)
            if group.count > 1 {
                Text("\(group.count)")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 1 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(background)
                if isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                }
            }
        )
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: 4 * scale)
            }
        }
        .onHover { hovering = $0 }
        .help(representative.displayTitle)
    }

    private var background: Color {
        if isActive { return Color.white.opacity(0.22) }
        if hovering { return Color.white.opacity(0.18) }
        return Color.white.opacity(0.08)
    }
}

/// Reports this view's window-level frame in screen coordinates.
private struct WindowFrameReader: NSViewRepresentable {
    let onFrame: (NSRect) -> Void

    func makeNSView(context: Context) -> FrameView {
        let v = FrameView()
        v.onFrame = onFrame
        return v
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.onFrame = onFrame
    }

    final class FrameView: NSView {
        var onFrame: ((NSRect) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        private func reportFrame() {
            guard let window = self.window else { return }
            let inWindow = convert(bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            onFrame?(onScreen)
        }
    }
}
