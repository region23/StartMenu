# Start Menu

A Windows-10-style taskbar and Start menu for macOS.

A thin bar along the bottom of the screen shows a chip per open window on the
current Space, click to focus, right-click to close or minimize. The Start
button opens a menu with a search field, a shortcut to the `/Applications`
folder (click to expand), and a list of apps pinned in your system Dock. The
footer has a gear for settings and a power icon to quit.

Inspired by [boringBar](https://boringbar.app/). macOS 14+ only.

## Features

- **Taskbar chips** for every window on the current Space. Icon + title. Active
  window is highlighted with an underline. Minimized windows stay visible
  (dimmed) so you can restore them.
- **Left-click a chip** — focus the window.
- **Right-click a chip** — Close / Minimize (via Accessibility API with
  CGWindowID-precise matching).
- **Start menu popup** — flush with the left edge and top of the bar:
  - Search field (filters all apps as you type)
  - `Applications ›` row at the top, click to expand into the full
    `/Applications` + `~/Applications` + `/System/Applications` list
  - `From Dock` section showing apps pinned in your system Dock (read from
    `com.apple.dock.persistent-apps`)
  - Footer: Settings (gear) and Quit (power)
- **Settings** (inside Start menu): UI scale (Small → Huge), Hide system Dock,
  Launch at login.
- **Global hotkey** `⌃Space` — toggle the Start menu.
- **Hide system Dock** — sets `autohide` and a huge `autohide-delay` via
  `CFPreferencesSetAppValue`, restores on quit.
- **Launch at login** — registers the app with `SMAppService.mainApp`.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`) — the Xcode project is generated from
  `project.yml`, not checked in.

## Build & run

```sh
./scripts/run.sh
```

This script:

1. Regenerates `StartMenu.xcodeproj` via XcodeGen
2. Builds the Debug configuration with `xcodebuild`
3. Resets TCC grants for the bundle id (see Permissions below)
4. Installs the fresh `.app` into `~/Applications/StartMenu.app`
5. Kills any running instance and launches the new one

On first launch (and after every rebuild — see note below) an onboarding
window asks for **Accessibility** permission. Click **Request**, then toggle
`StartMenu` on in *System Settings → Privacy & Security → Accessibility*. The
onboarding window auto-closes as soon as the grant takes effect.

## Permissions

| Permission                                  | Needed for                                          |
|----------------------------------------------|-----------------------------------------------------|
| Accessibility                                | Enumerating, focusing, closing, minimizing windows  |
| Automation → System Events                   | Bringing other apps to front on chip click          |
| (optional, future) Screen Recording          | Window thumbnails on hover                          |

## Architecture

Modules under `StartMenu/`:

- `App/` — `StartMenuApp` (SwiftUI `@main`), `AppDelegate`, `AppEnvironment`
  (DI container)
- `Services/`
  - `WindowService` — enumerates on-screen windows via
    `CGWindowListCopyWindowInfo` and scans minimized windows via Accessibility
  - `WindowController` — activate / close / minimize using AX (with
    `_AXUIElementGetWindow` for precise CGWindowID matching) and System Events
    AppleScript for app-level foregrounding
  - `StartMenuService` — scans `/Applications`, `~/Applications`,
    `/System/Applications` and provides fuzzy search
  - `DockAppsService` — reads pinned apps from `com.apple.dock` via
    `CFPreferencesCopyAppValue`, observes `com.apple.dock.prefchanged`
  - `PermissionsService` — AX + Screen Recording status and deep links into
    System Settings
  - `DockControlService` — hides/restores the system Dock
  - `AutostartService` — `SMAppService.mainApp` wrapper
  - `HotkeyService` — Carbon `RegisterEventHotKey` for the global `⌃Space`
  - `AppIconService` — `NSWorkspace.icon(forFile:)` cache
  - `AXPrivate` — `@_silgen_name` binding for `_AXUIElementGetWindow`
- `Models/` — `WindowInfo`, `AppInfo`, `BarConfig` (UI scale)
- `UI/Bar/` — `BarWindowController` (borderless `.nonactivatingPanel` at
  `.statusBar` level), `BarView`, chip rendering
- `UI/StartMenu/` — `KeyablePanel` subclass (so the search field can become
  first responder without activating the whole app), `StartMenuWindowController`,
  `StartMenuView`
- `UI/Onboarding/` — permission-request window
- `Store/` — `SettingsStore` (`@AppStorage`-style `UserDefaults` wrapper)

## Releases

To cut a tagged release, build a Release `.app`, package it as a DMG
(with a drag-to-`/Applications` layout), tag and push, and publish a
GitHub release with auto-generated release notes:

```sh
./scripts/release.sh 0.1.0
```

The script requires a clean working tree on `main`, the `gh` CLI
authenticated, and `xcodegen` installed. It passes
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` to `xcodebuild` so the
version in `Info.plist` matches the tag; the build number defaults to the
commit count on `HEAD`. The DMG is produced with the built-in `hdiutil`
(UDZO compression) and contains `StartMenu.app` plus an alias to
`/Applications` so users can drag the app in.

Release artifacts land in `build/release/StartMenu-<version>.dmg` and are
uploaded to the GitHub release as an asset.

**Note on downloaded releases:** builds are ad-hoc signed and not
notarized, so Gatekeeper will refuse to open the app on first launch.
After mounting the DMG and copying to `/Applications`, strip the
quarantine attribute:

```sh
xattr -cr /Applications/StartMenu.app
```

Or right-click the app → *Open* → *Open* to accept once.

## Dev notes

### Why the rebuild always re-prompts for Accessibility

The project is ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`). Every rebuild changes
the binary's `cdhash`, which is part of an ad-hoc designated requirement, so
TCC silently invalidates the Accessibility grant even though *System Settings*
still shows the checkbox as enabled — `AXIsProcessTrusted()` returns `false`.

`scripts/run.sh` works around this by calling
`tccutil reset Accessibility app.pavlenko.startmenu` before installing, so
every build starts from a clean TCC state. Re-granting is a single toggle in
System Settings and the onboarding window polls `AXIsProcessTrusted()` and
auto-closes as soon as it flips to `true`.

The proper fix is signing with a stable identity (Apple Development cert or a
self-signed code signing cert trusted for `codeSign` via
`security add-trusted-cert`). That removes the need for `tccutil reset` and
the onboarding dance entirely.

### Logs

The app logs through `os.Logger` with the `app.pavlenko.startmenu` subsystem.
To stream logs in a terminal:

```sh
log stream --level info --predicate subsystem==\"app.pavlenko.startmenu\" --style compact
```

### Icon

`scripts/gen-icon.swift` draws the app icon (dark gradient + 2×2 grid of white
squares) programmatically and writes all `AppIcon.appiconset` sizes. Rerun it
if you tweak the design.

## Roadmap

- Window thumbnails on hover (`ScreenCaptureKit`)
- Groups for multiple windows per app (stacked chip with count)
- Spaces switcher on the right side of the bar
- Multi-display (per-screen bar)
- Fullscreen and Stage Manager edge cases
- Stable code signing identity so TCC grants persist across rebuilds
