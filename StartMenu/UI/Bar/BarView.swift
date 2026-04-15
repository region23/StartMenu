import AppKit
import SwiftUI

struct BarView: View {
    @ObservedObject var windowService: WindowService
    @ObservedObject var settingsStore: SettingsStore
    let windowController: WindowController
    let onStartButtonFrame: (NSRect) -> Void
    let onStartButtonTap: () -> Void

    private var scale: Double { settingsStore.uiScale }
    private var groups: [WindowGroup] { WindowGroup.group(windowService.windows) }

    var body: some View {
        HStack(spacing: 8 * scale) {
            StartButton(scale: scale, onTap: onStartButtonTap, onFrame: onStartButtonFrame)
            Divider().frame(height: 28 * scale).opacity(0.25)
            WindowChipsList(
                groups: groups,
                activePID: windowService.activeAppPID,
                scale: scale,
                compact: settingsStore.compactChips,
                onTap: { windowController.activate($0) },
                onClose: { windowController.close($0) },
                onMinimize: { windowController.minimize($0) }
            )
            .layoutPriority(1)
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
    let compact: Bool
    let onTap: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onMinimize: (WindowInfo) -> Void

    @State private var hoveredChipID: pid_t?
    @State private var edgeFrames = EdgeChipFrames()
    @State private var viewportWidth: CGFloat = 0

    private static let coordinateSpaceName = "chipScroll"
    private static let edgeSlack: CGFloat = 1.0
    private static let hoverAnimation = Animation.easeOut(duration: 0.14)

    private var canScrollLeft: Bool {
        guard let frame = edgeFrames.first else { return false }
        return frame.minX < -Self.edgeSlack
    }

    private var canScrollRight: Bool {
        guard let frame = edgeFrames.last else { return false }
        return frame.maxX > viewportWidth + Self.edgeSlack
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8 * scale) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        WindowChipView(
                            group: group,
                            isActive: group.id == activePID,
                            isHovered: hoveredChipID == group.id,
                            scale: scale,
                            compact: compact
                        )
                        .id(group.id)
                        .background(
                            edgeFrameReader(for: index, total: groups.count)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { inside in
                            guard compact else { return }
                            withAnimation(Self.hoverAnimation) {
                                if inside {
                                    hoveredChipID = group.id
                                } else if hoveredChipID == group.id {
                                    hoveredChipID = nil
                                }
                            }
                        }
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
            .coordinateSpace(name: Self.coordinateSpaceName)
            .background(
                GeometryReader { outer in
                    Color.clear
                        .onAppear { viewportWidth = outer.size.width }
                        .onChange(of: outer.size.width) { _, new in viewportWidth = new }
                }
            )
            .onPreferenceChange(EdgeChipFramesPreferenceKey.self) { edgeFrames = $0 }
            .overlay(alignment: .leading) {
                if canScrollLeft, let first = groups.first?.id {
                    ScrollChevron(direction: .left, scale: scale) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(first, anchor: .leading)
                        }
                    }
                    .padding(.leading, 2)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if canScrollRight, let last = groups.last?.id {
                    ScrollChevron(direction: .right, scale: scale) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(last, anchor: .trailing)
                        }
                    }
                    .padding(.trailing, 2)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: canScrollLeft)
            .animation(.easeOut(duration: 0.15), value: canScrollRight)
        }
    }

    @ViewBuilder
    private func edgeFrameReader(for index: Int, total: Int) -> some View {
        if index == 0 || index == total - 1 {
            GeometryReader { geo in
                Color.clear.preference(
                    key: EdgeChipFramesPreferenceKey.self,
                    value: EdgeChipFrames(
                        first: index == 0 ? geo.frame(in: .named(Self.coordinateSpaceName)) : nil,
                        last: index == total - 1 ? geo.frame(in: .named(Self.coordinateSpaceName)) : nil
                    )
                )
            }
        } else {
            Color.clear
        }
    }
}

private struct EdgeChipFrames: Equatable {
    var first: CGRect?
    var last: CGRect?
}

private struct EdgeChipFramesPreferenceKey: PreferenceKey {
    static var defaultValue = EdgeChipFrames()

    static func reduce(value: inout EdgeChipFrames, nextValue: () -> EdgeChipFrames) {
        let next = nextValue()
        if let first = next.first { value.first = first }
        if let last = next.last { value.last = last }
    }
}

private struct ScrollChevron: View {
    enum Direction { case left, right }

    let direction: Direction
    let scale: Double
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 12 * scale, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22 * scale, height: 28 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(hovering ? 0.55 : 0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct WindowChipView: View {
    let group: WindowGroup
    let isActive: Bool
    let isHovered: Bool
    let scale: Double
    let compact: Bool

    private var representative: WindowInfo { group.representative }
    private var dimmed: Bool { group.isAllMinimized }
    private var showLabel: Bool { !compact || isHovered }
    private var labelWidth: CGFloat {
        guard showLabel else { return 0 }
        let font = NSFont.systemFont(ofSize: 12 * scale)
        let raw = (representative.displayTitle as NSString).size(withAttributes: [.font: font]).width
        return min(170 * scale, ceil(raw))
    }

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
                .frame(width: labelWidth, alignment: .leading)
                .opacity(showLabel ? (dimmed ? 0.6 : 1.0) : 0)
                .italic(dimmed)
                .clipped()
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
        .animation(.easeOut(duration: 0.14), value: showLabel)
    }

    private var background: Color {
        if isActive { return Color.white.opacity(0.22) }
        if isHovered { return Color.white.opacity(0.18) }
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
