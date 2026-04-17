# Start Menu

A Windows-10-style taskbar and Start menu for macOS.

A thin bar along the bottom of the screen shows a chip per open window on the
current Space, click to focus, right-click to close or minimize. The Start
button opens a menu with a search field, a shortcut to the `/Applications`
folder (click to expand), and a list of apps pinned in your system Dock. The
footer has a gear for settings and a power icon to quit.

Inspired by [boringBar](https://boringbar.app/). macOS 14+ only.

## Install

### Via Homebrew (recommended)

```sh
brew install --cask region23/tap/startmenu
```

That's it — Homebrew handles Gatekeeper quarantine for you and the app launches cleanly on the first try. To upgrade later:

```sh
brew upgrade --cask region23/tap/startmenu
```

### Manual install (DMG)

Download the latest `StartMenu-*.dmg` from [Releases](https://github.com/region23/StartMenu/releases), mount it and drag `StartMenu.app` into `/Applications`.

Because the app is ad-hoc signed (no paid Apple Developer ID, no notarization), macOS Gatekeeper will block the first launch with *"StartMenu cannot be opened because Apple cannot check it for malicious software"*. Strip the quarantine attribute once:

```sh
xattr -dr com.apple.quarantine /Applications/StartMenu.app
```

After that the app launches normally. The Homebrew path above avoids this entirely.

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

### Power-user private build

The repo now has a separate `StartMenuPowerUser` target for Dock/window-server
experiments. It uses a different bundle id, defaults store, signing
requirement, install path and diagnostics surface, so it stays isolated from
the public app:

```sh
./scripts/run-power-user.sh
```

This builds and installs `~/Applications/StartMenuPowerUser.app` with bundle id
`app.pavlenko.startmenu.poweruser`. The private build shares the same UI, but
adds a **Power-user private build** section in Settings with feature flags and
diagnostics for the Dock-owned reservation path.

When the `Real desktop reservation` flag is enabled in the private build,
Start Menu keeps the system Dock alive at the bottom of the screen with a
minimal profile and places the Start Menu bar inside that reserved strip.
Other apps then lay out above the Dock-owned area instead of opening or
maximizing underneath the bar. If reservation cannot be measured cleanly, the
private build reports a warning in diagnostics and falls back to the requested
bar height while the public AX clamp remains available as a secondary safety
net.

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

To cut a tagged release manually, build a Release `.app`, package it as a
DMG (with a drag-to-`/Applications` layout), tag and push, and publish a
GitHub release:

```sh
./scripts/release.sh 0.1.0
```

If you already prepared custom release notes in Markdown, pass them with
`--notes-file`:

```sh
./scripts/release.sh 0.1.0 --notes-file build/release/release-notes-0.1.0.md
```

If you use Codex in this repository, there is also a local slash command:

```text
/release 0.1.0
```

It lives in [release.md](/Users/pavlenko/code/start_menu/.codex/commands/release.md) and performs the full release workflow:

- inspects commits and diffs since the last release
- writes a polished bilingual entry into [CHANGELOG.md](/Users/pavlenko/code/start_menu/CHANGELOG.md)
- writes matching GitHub release notes in English and Russian
- commits and pushes `main`
- runs `./scripts/release.sh` with the generated notes file

The script requires a clean working tree on `main`, the `gh` CLI
authenticated, and `xcodegen` installed. It passes
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` to `xcodebuild` so the
version in `Info.plist` matches the tag; the build number defaults to the
commit count on `HEAD`. The DMG is produced with the built-in `hdiutil`
(UDZO compression) and contains `StartMenu.app` plus an alias to
`/Applications` so users can drag the app in.

Release artifacts land in `build/release/StartMenu-<version>.dmg` and are
uploaded to the GitHub release as an asset. When `--notes-file` is used,
that Markdown body is published as the GitHub release description instead of
GitHub auto-generated notes.

After the GitHub release is live the script also updates the Homebrew
cask in [region23/homebrew-tap](https://github.com/region23/homebrew-tap)
so `brew upgrade --cask region23/tap/startmenu` picks up the new
version. The tap is cloned into `build/release/homebrew-tap`, the
`Casks/startmenu.rb` file is rewritten with the fresh `version`, `url`
and `sha256`, then committed and pushed.

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

The public app logs through `os.Logger` with the `app.pavlenko.startmenu`
subsystem. The private build uses `app.pavlenko.startmenu.poweruser`.
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
- Spaces switcher on the right side of the bar
- Multi-display (per-screen bar)
- Stage Manager edge cases
- Stable code signing identity so TCC grants persist across rebuilds
