import AppKit
import SwiftUI

struct BarView: View {
    @ObservedObject var windowService: WindowService
    @ObservedObject var menuBarExtrasService: MenuBarExtrasService
    @ObservedObject var settingsStore: SettingsStore
    let windowController: WindowController
    let onLaunchApp: (AppInfo) -> Void
    let onStartButtonFrame: (NSRect) -> Void
    let onStartButtonTap: () -> Void

    private var scale: Double { settingsStore.uiScale }
    private var groups: [WindowGroup] { WindowGroup.group(windowService.windows) }
    private var groupedByBundleID: [String: WindowGroup] {
        groups.reduce(into: [:]) { result, group in
            guard let bundleID = group.ownerBundleID else { return }
            result[bundleID] = result[bundleID] ?? group
        }
    }
    private var pinnedItems: [PinnedBarItem] {
        settingsStore.pinnedBundleIDs.map { bundleID in
            let resolvedApp = AppInfo.resolve(bundleID: bundleID)
            return PinnedBarItem(
                bundleID: bundleID,
                name: groupedByBundleID[bundleID]?.ownerName ?? resolvedApp?.name ?? AppInfo.fallbackName(for: bundleID),
                appURL: resolvedApp?.url,
                runningGroup: groupedByBundleID[bundleID]
            )
        }
    }
    private var unpinnedGroups: [WindowGroup] {
        groups.filter { group in
            guard let bundleID = group.ownerBundleID else { return true }
            return !settingsStore.isPinned(bundleID)
        }
    }

    var body: some View {
        HStack(spacing: 8 * scale) {
            StartButton(scale: scale, onTap: onStartButtonTap, onFrame: onStartButtonFrame)

            if !pinnedItems.isEmpty {
                PinnedAppsStrip(
                    items: pinnedItems,
                    activePID: windowService.activeAppPID,
                    scale: scale,
                    onTogglePin: { settingsStore.togglePin($0.bundleID) },
                    onActivate: { item in
                        if let window = item.runningGroup?.representative {
                            windowController.activate(window)
                            return
                        }
                        if let app = item.appInfo {
                            onLaunchApp(app)
                        }
                    },
                    onActivateWindow: { windowController.activate($0) },
                    onCloseWindow: { windowController.close($0) },
                    onMinimizeWindow: { windowController.minimize($0) }
                )

                BarSectionDivider(scale: scale, emphasized: true)
            } else {
                BarSectionDivider(scale: scale, emphasized: false)
            }

            WindowChipsList(
                groups: unpinnedGroups,
                activePID: windowService.activeAppPID,
                scale: scale,
                compact: settingsStore.compactChips,
                onTap: { windowController.activate($0) },
                onClose: { windowController.close($0) },
                onMinimize: { windowController.minimize($0) },
                isPinned: { group in
                    guard let bundleID = group.ownerBundleID else { return false }
                    return settingsStore.isPinned(bundleID)
                },
                onTogglePin: { group in
                    guard let bundleID = group.ownerBundleID else { return }
                    settingsStore.togglePin(bundleID)
                }
            )
            .layoutPriority(1)

            Spacer(minLength: 8 * scale)

            TrashButton(scale: scale)

            MenuBarExtrasButton(
                service: menuBarExtrasService,
                scale: scale
            )
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

private struct BarSectionDivider: View {
    let scale: Double
    let emphasized: Bool

    private var lineHeight: CGFloat {
        CGFloat((emphasized ? 38 : 30) * scale)
    }

    private var lineWidth: CGFloat {
        max(1, CGFloat((emphasized ? 1.2 : 1.0) * scale))
    }

    private var highlightWidth: CGFloat {
        max(1, lineWidth * 0.9)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: lineWidth / 2)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0),
                            Color.black.opacity(emphasized ? 0.24 : 0.18),
                            Color.black.opacity(emphasized ? 0.24 : 0.18),
                            Color.black.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: lineWidth, height: lineHeight)

            RoundedRectangle(cornerRadius: highlightWidth / 2)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(emphasized ? 0.12 : 0.08),
                            Color.white.opacity(emphasized ? 0.12 : 0.08),
                            Color.white.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: highlightWidth, height: lineHeight - 2 * scale)
                .offset(x: lineWidth * 0.7)
        }
        .padding(.horizontal, emphasized ? 9 * scale : 5 * scale)
        .accessibilityHidden(true)
    }
}

private struct PinnedBarItem: Identifiable {
    let bundleID: String
    let name: String
    let appURL: URL?
    let runningGroup: WindowGroup?

    var id: String { bundleID }
    var appInfo: AppInfo? {
        guard let appURL else { return nil }
        return AppInfo(bundleID: bundleID, name: name, url: appURL)
    }
}

private struct PinnedAppsStrip: View {
    let items: [PinnedBarItem]
    let activePID: pid_t?
    let scale: Double
    let onTogglePin: (PinnedBarItem) -> Void
    let onActivate: (PinnedBarItem) -> Void
    let onActivateWindow: (WindowInfo) -> Void
    let onCloseWindow: (WindowInfo) -> Void
    let onMinimizeWindow: (WindowInfo) -> Void

    private var stripWidth: CGFloat {
        let chipWidth = CGFloat(42 * scale)
        let spacing = CGFloat(6 * scale)
        let count = CGFloat(items.count)
        let width = count * chipWidth + max(0, count - 1) * spacing
        return min(width, CGFloat(240 * scale))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6 * scale) {
                ForEach(items) { item in
                    PinnedAppChipView(
                        item: item,
                        isActive: item.runningGroup?.id == activePID,
                        scale: scale,
                        onTap: { onActivate(item) }
                    )
                    .contextMenu {
                        if let group = item.runningGroup {
                            if group.windows.count > 1 {
                                ForEach(group.windows) { win in
                                    Button(win.displayTitle) { onActivateWindow(win) }
                                }
                                Divider()
                            }
                            Button("Minimize") { onMinimizeWindow(group.representative) }
                            Button("Close") { onCloseWindow(group.representative) }
                            Divider()
                        } else {
                            Button("Open") { onActivate(item) }
                                .disabled(item.appInfo == nil)
                            Divider()
                        }

                        Button("Unpin from Bar") { onTogglePin(item) }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        // ScrollView has no useful intrinsic width inside an HStack, so
        // `maxWidth` alone lets the pinned strip collapse to zero. Give
        // it a concrete width derived from the number of pinned apps.
        .frame(width: stripWidth)
    }
}

private struct PinnedAppChipView: View {
    let item: PinnedBarItem
    let isActive: Bool
    let scale: Double
    let onTap: () -> Void

    @State private var hovering = false

    private var isRunning: Bool { item.runningGroup != nil }
    private var icon: NSImage {
        if let representative = item.runningGroup?.representative,
           let icon = AppIconService.shared.icon(forPID: representative.ownerPID) {
            return icon
        }
        if let icon = AppIconService.shared.icon(forBundleID: item.bundleID) {
            return icon
        }
        return AppIconService.shared.placeholderIcon()
    }

    var body: some View {
        Button(action: onTap) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20 * scale, height: 20 * scale)
                .opacity(isRunning ? 1.0 : 0.72)
                .frame(width: 38 * scale, height: 36 * scale)
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
                    if isRunning {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isActive ? Color.accentColor : Color.white.opacity(0.35))
                            .frame(height: 2)
                            .padding(.horizontal, 5 * scale)
                            .offset(y: 4 * scale)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(item.name)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isActive { return Color.white.opacity(0.22) }
        if hovering { return Color.white.opacity(0.18) }
        return Color.white.opacity(0.08)
    }
}

private struct MenuBarExtrasButton: View {
    @ObservedObject var service: MenuBarExtrasService
    let scale: Double

    @State private var isPresented = false
    @State private var hovering = false
    @State private var hoveringPopover = false
    @State private var pendingDismiss: DispatchWorkItem?

    private static let dismissDelay: TimeInterval = 0.18

    var body: some View {
        Button {
            service.refresh()
            pendingDismiss?.cancel()
            pendingDismiss = nil
            isPresented.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.circle.fill")
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36 * scale, height: 36 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(hovering ? 0.18 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .help("Menu bar items")
        .onHover { inside in
            hovering = inside
            handleHoverChange()
        }
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            MenuBarExtrasPopover(
                service: service,
                scale: scale,
                onHoverChange: { inside in
                    hoveringPopover = inside
                    handleHoverChange()
                },
                onDismiss: { isPresented = false }
            )
        }
    }

    private func handleHoverChange() {
        pendingDismiss?.cancel()
        pendingDismiss = nil

        guard isPresented else { return }
        guard !hovering && !hoveringPopover else { return }

        let work = DispatchWorkItem {
            isPresented = false
        }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissDelay, execute: work)
    }
}

private struct TrashButton: View {
    let scale: Double

    @State private var hovering = false

    private var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
    }

    private var icon: NSImage {
        AppIconService.shared.icon(for: trashURL)
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(trashURL)
        } label: {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20 * scale, height: 20 * scale)
                .frame(width: 36 * scale, height: 36 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(hovering ? 0.18 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .help("Trash")
        .onHover { hovering = $0 }
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
    let isPinned: (WindowGroup) -> Bool
    let onTogglePin: (WindowGroup) -> Void

    @State private var hoveredChipID: pid_t?
    @State private var popoverGroupID: pid_t?
    @State private var hoveredPopoverGroupID: pid_t?
    @State private var edgeFrames = EdgeChipFrames()
    @State private var viewportWidth: CGFloat = 0
    @State private var pendingChipCollapse: DispatchWorkItem?
    @State private var pendingHoverClear: DispatchWorkItem?

    private static let coordinateSpaceName = "chipScroll"
    private static let edgeSlack: CGFloat = 1.0
    private static let hoverAnimation = Animation.interactiveSpring(
        response: 0.24,
        dampingFraction: 0.86,
        blendDuration: 0.12
    )
    private static let compactChipCollapseDelay: TimeInterval = 0.11
    private static let popoverDismissDelay: TimeInterval = 0.24

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
                HStack(spacing: 8 * scale) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        WindowChipView(
                            group: group,
                            isActive: group.id == activePID,
                            isHovered: isGroupExpanded(group.id),
                            scale: scale,
                            compact: compact
                        )
                        .id(group.id)
                        .background(
                            edgeFrameReader(for: index, total: groups.count)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { inside in
                            handleChipHoverChange(inside, for: group)
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
                            if group.ownerBundleID != nil {
                                Divider()
                                Button(isPinned(group) ? "Unpin from Bar" : "Pin to Bar") {
                                    onTogglePin(group)
                                }
                            }
                        }
                        .popover(
                            isPresented: hoverPopoverBinding(for: group),
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .bottom
                        ) {
                            if group.count > 1 {
                                GroupWindowPicker(
                                    group: group,
                                    scale: scale,
                                    onHoverChange: { inside in handlePopoverHoverChange(inside, for: group.id) },
                                    onActivate: { window in
                                        clearHoverState()
                                        onTap(window)
                                    }
                                )
                            }
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

    private func handleChipHoverChange(_ inside: Bool, for group: WindowGroup) {
        pendingChipCollapse?.cancel()
        pendingChipCollapse = nil
        pendingHoverClear?.cancel()
        pendingHoverClear = nil

        if inside {
            withAnimation(Self.hoverAnimation) {
                hoveredChipID = group.id
                if let activePopover = popoverGroupID, activePopover != group.id {
                    popoverGroupID = nil
                    if hoveredPopoverGroupID == activePopover {
                        hoveredPopoverGroupID = nil
                    }
                }
                if group.count > 1 {
                    popoverGroupID = group.id
                } else if popoverGroupID == group.id {
                    popoverGroupID = nil
                }
            }
            return
        }

        scheduleChipCollapse(for: group.id)
        scheduleHoverClear(for: group.id)
    }

    private func handlePopoverHoverChange(_ inside: Bool, for groupID: pid_t) {
        pendingChipCollapse?.cancel()
        pendingChipCollapse = nil
        pendingHoverClear?.cancel()
        pendingHoverClear = nil

        if inside {
            withAnimation(Self.hoverAnimation) {
                hoveredPopoverGroupID = groupID
                hoveredChipID = groupID
                popoverGroupID = groupID
            }
            return
        }

        if hoveredPopoverGroupID == groupID {
            hoveredPopoverGroupID = nil
        }
        scheduleHoverClear(for: groupID)
    }

    private func scheduleChipCollapse(for groupID: pid_t) {
        let work = DispatchWorkItem {
            guard hoveredChipID == groupID else { return }
            guard hoveredPopoverGroupID != groupID else { return }
            guard popoverGroupID != groupID else { return }
            withAnimation(Self.hoverAnimation) {
                hoveredChipID = nil
            }
        }
        pendingChipCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.compactChipCollapseDelay, execute: work)
    }

    private func scheduleHoverClear(for groupID: pid_t) {
        let work = DispatchWorkItem {
            guard hoveredChipID != groupID else { return }
            guard hoveredPopoverGroupID != groupID else { return }
            withAnimation(Self.hoverAnimation) {
                if popoverGroupID == groupID {
                    popoverGroupID = nil
                }
            }
        }
        pendingHoverClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverDismissDelay, execute: work)
    }

    private func clearHoverState() {
        pendingChipCollapse?.cancel()
        pendingChipCollapse = nil
        pendingHoverClear?.cancel()
        pendingHoverClear = nil
        hoveredChipID = nil
        hoveredPopoverGroupID = nil
        popoverGroupID = nil
    }

    private func hoverPopoverBinding(for group: WindowGroup) -> Binding<Bool> {
        Binding(
            get: { group.count > 1 && popoverGroupID == group.id },
            set: { presented in
                if presented {
                    withAnimation(Self.hoverAnimation) {
                        popoverGroupID = group.id
                    }
                } else {
                    pendingChipCollapse?.cancel()
                    pendingChipCollapse = nil
                    pendingHoverClear?.cancel()
                    pendingHoverClear = nil
                    withAnimation(Self.hoverAnimation) {
                        if hoveredChipID == group.id {
                            hoveredChipID = nil
                        }
                        if hoveredPopoverGroupID == group.id {
                            hoveredPopoverGroupID = nil
                        }
                        if popoverGroupID == group.id {
                            popoverGroupID = nil
                        }
                    }
                }
            }
        )
    }

    private func isGroupExpanded(_ groupID: pid_t) -> Bool {
        hoveredChipID == groupID || hoveredPopoverGroupID == groupID || popoverGroupID == groupID
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
    private var chipTitle: String { group.ownerName }
    private var dimmed: Bool { group.isAllMinimized }
    private var showLabel: Bool { !compact || isHovered }
    private var labelWidth: CGFloat {
        guard showLabel else { return 0 }
        let font = NSFont.systemFont(ofSize: 12 * scale)
        let raw = (chipTitle as NSString).size(withAttributes: [.font: font]).width
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
            Text(chipTitle)
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
        .animation(
            .interactiveSpring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.12),
            value: showLabel
        )
    }

    private var background: Color {
        if isActive { return Color.white.opacity(0.22) }
        if isHovered { return Color.white.opacity(0.18) }
        return Color.white.opacity(0.08)
    }
}

private struct GroupWindowPicker: View {
    let group: WindowGroup
    let scale: Double
    let onHoverChange: (Bool) -> Void
    let onActivate: (WindowInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(group.ownerName)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4 * scale)

            ForEach(group.windows) { window in
                GroupWindowPickerRow(
                    window: window,
                    scale: scale,
                    onActivate: { onActivate(window) }
                )
            }
        }
        .padding(12 * scale)
        .frame(width: 280 * scale)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08))
        )
        .onHover(perform: onHoverChange)
    }
}

private struct GroupWindowPickerRow: View {
    let window: WindowInfo
    let scale: Double
    let onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8 * scale) {
                if let icon = AppIconService.shared.icon(forPID: window.ownerPID) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18 * scale, height: 18 * scale)
                        .opacity(window.isMinimized ? 0.6 : 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(window.displayTitle)
                        .font(.system(size: 12 * scale, weight: .medium))
                        .lineLimit(1)
                    if let subtitle = window.subtitle, !subtitle.isEmpty {
                        Text(window.isMinimized ? "\(subtitle) • Minimized" : subtitle)
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if window.isMinimized {
                        Text("Minimized")
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 6 * scale)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        Color.white.opacity(isHovered ? 0.22 : 0.0)
    }
}

private struct MenuBarExtrasPopover: View {
    @ObservedObject var service: MenuBarExtrasService
    let scale: Double
    let onHoverChange: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack {
                Text("Menu Bar Items")
                    .font(.system(size: 13 * scale, weight: .semibold))
                Spacer()
                Button {
                    service.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12 * scale, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            if !service.hasAccessibilityAccess {
                Text("Accessibility access is required to read and trigger menu bar items.")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if service.items.isEmpty {
                Text("No menu bar items found.")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2 * scale) {
                        ForEach(service.items) { item in
                            Button {
                                service.activate(item)
                                onDismiss()
                            } label: {
                                MenuBarExtraRow(item: item, scale: scale)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Activate") {
                                    service.activate(item)
                                    onDismiss()
                                }
                                if item.canShowMenu || item.canPress {
                                    Button("Open Menu") {
                                        service.showMenu(for: item)
                                        onDismiss()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360 * scale)
            }
        }
        .padding(14 * scale)
        .frame(width: 320 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08))
        )
        .onHover(perform: onHoverChange)
    }
}

private struct MenuBarExtraRow: View {
    let item: MenuBarExtraInfo
    let scale: Double

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10 * scale) {
            if let icon = AppIconService.shared.icon(forPID: item.ownerPID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20 * scale, height: 20 * scale)
            } else {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 20 * scale, height: 20 * scale)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 6 * scale)
        .background(
            Color.white.opacity(hovering ? 0.22 : 0.0),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
