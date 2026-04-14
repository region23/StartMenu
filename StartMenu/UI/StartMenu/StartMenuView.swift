import AppKit
import SwiftUI

struct StartMenuView: View {
    @ObservedObject var startMenuService: StartMenuService
    @ObservedObject var dockAppsService: DockAppsService
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var autostartService: AutostartService
    let onLaunch: (AppInfo) -> Void
    let onDismiss: () -> Void
    let onToggleDockHide: () -> Void
    let onQuit: () -> Void

    @State private var query: String = ""
    @State private var mode: Mode = .home
    @FocusState private var searchFocused: Bool

    private enum Mode { case home, allApps, settings }

    private var scale: Double { settingsStore.uiScale }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12 * scale)

            Divider().opacity(0.2)

            Group {
                if !query.isEmpty {
                    appList(startMenuService.search(query), emptyText: "No apps found")
                } else {
                    switch mode {
                    case .home: homeContent
                    case .allApps: allAppsContent
                    case .settings: settingsContent
                    }
                }
            }
            .padding(12 * scale)
            .frame(maxHeight: .infinity)

            Divider().opacity(0.2)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.15)
            }
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 6,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 6
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 6,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 6
            ).stroke(Color.white.opacity(0.08))
        )
        .onAppear {
            mode = .home
            query = ""
            DispatchQueue.main.async { searchFocused = true }
        }
        .onExitCommand { onDismiss() }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * scale))
                .focused($searchFocused)
                .onSubmit {
                    if let first = startMenuService.search(query).first { onLaunch(first) }
                }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Home mode

    private var homeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4 * scale) {
                ApplicationsFolderRow(scale: scale, onActivate: { mode = .allApps })
                    .padding(.bottom, 10 * scale)

                if !dockAppsService.apps.isEmpty {
                    sectionHeader("From Dock")
                    ForEach(dockAppsService.apps) { app in
                        appRow(app) {
                            Button("Launch") { onLaunch(app) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - All apps mode

    private var allAppsContent: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            backHeader { mode = .home }
            appList(startMenuService.apps, emptyText: "No applications found")
        }
    }

    // MARK: - Settings mode

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            backHeader { mode = .home }
                .padding(.bottom, 6 * scale)

            ScrollView {
                VStack(alignment: .leading, spacing: 14 * scale) {
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        Text("UI Scale")
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        ForEach(UIScale.allCases) { option in
                            Button {
                                settingsStore.uiScale = option.rawValue
                            } label: {
                                HStack {
                                    Image(systemName: isSelectedScale(option) ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(.white)
                                    Text("\(option.label)  \(Int(option.rawValue * 100))%")
                                        .font(.system(size: 13 * scale))
                                    Spacer()
                                }
                                .padding(.horizontal, 8 * scale)
                                .padding(.vertical, 6 * scale)
                                .background(
                                    Color.white.opacity(isSelectedScale(option) ? 0.12 : 0.0),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider().opacity(0.2)

                    Toggle(isOn: Binding(
                        get: { settingsStore.hideDock },
                        set: { _ in onToggleDockHide() }
                    )) {
                        Text("Hide system Dock")
                            .font(.system(size: 13 * scale))
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: Binding(
                        get: { autostartService.isEnabled },
                        set: { autostartService.setEnabled($0) }
                    )) {
                        Text("Launch at login")
                            .font(.system(size: 13 * scale))
                    }
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8 * scale) {
            footerButton(systemImage: "gearshape.fill", help: "Settings") {
                mode = (mode == .settings) ? .home : .settings
            }

            Spacer()

            footerButton(systemImage: "power", help: "Quit Start Menu", action: onQuit)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
    }

    @ViewBuilder
    private func footerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16 * scale))
                .foregroundStyle(.white)
                .frame(width: 32 * scale, height: 32 * scale)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func backHeader(onBack: @escaping () -> Void) -> some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12 * scale, weight: .semibold))
                Text("Back").font(.system(size: 13 * scale, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 6 * scale)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2 * scale)
    }

    private func isSelectedScale(_ option: UIScale) -> Bool {
        abs(option.rawValue - settingsStore.uiScale) < 0.001
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func appList(_ items: [AppInfo], emptyText: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2 * scale) {
                ForEach(items) { app in
                    appRow(app) {
                        Button("Launch") { onLaunch(app) }
                    }
                }
                if items.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8 * scale)
                }
            }
        }
    }

    @ViewBuilder
    private func appRow<Menu: View>(_ app: AppInfo, @ViewBuilder menu: () -> Menu) -> some View {
        AppRow(app: app, scale: scale)
            .contentShape(Rectangle())
            .onTapGesture { onLaunch(app) }
            .contextMenu { menu() }
    }
}

private struct ApplicationsFolderRow: View {
    let scale: Double
    let onActivate: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.white)
                .font(.system(size: 15 * scale))
                .frame(width: 28 * scale, height: 28 * scale)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            Text("Applications")
                .font(.system(size: 14 * scale, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 8 * scale)
        .contentShape(Rectangle())
        .background(
            Color.white.opacity(hovering ? 0.24 : 0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hovering = $0 }
        .onTapGesture { onActivate() }
    }
}

private struct AppRow: View {
    let app: AppInfo
    let scale: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(nsImage: AppIconService.shared.icon(for: app.url))
                .resizable()
                .interpolation(.high)
                .frame(width: 24 * scale, height: 24 * scale)
            Text(app.name)
                .font(.system(size: 13 * scale))
                .lineLimit(1)
            Spacer()
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
