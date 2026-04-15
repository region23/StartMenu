# Power-User Private Build

## Goal

Keep experimental window-server and Dock-adjacent features isolated from the
main app and release flow.

This mode is for local or enthusiast builds only. It must not share the same
distribution path, bundle identifier, launch agent, or default settings store
with the public app.

## Principles

- Separate target and bundle ID.
- Compile-time gating first, runtime gating second.
- No private behavior in the public binary.
- Public build keeps using AppKit + Accessibility only.
- Private build can depend on extra setup steps such as reduced SIP or a
  scripting addition, but those assumptions stay outside the public product.

## Proposed Layout

Add a second app target:

- `StartMenu`
  Public build. Current shipping app.
- `StartMenuPowerUser`
  Experimental build with private integrations enabled.

Add separate build settings:

- Public target:
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = PUBLIC_BUILD`
- Private target:
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS = PUBLIC_BUILD PRIVATE_BUILD`

Use separate identifiers and storage:

- Public bundle ID:
  `app.pavlenko.startmenu`
- Private bundle ID:
  `app.pavlenko.startmenu.poweruser`
- Private defaults suite:
  `app.pavlenko.startmenu.poweruser.defaults`

## Code Boundaries

Introduce narrow protocols in shared code:

- `WindowConstraining`
  Owns "keep windows above bar" behavior.
- `DesktopReservationStrategy`
  Answers whether the system area can be truly reserved or only simulated.
- `PrivateFeatureAvailability`
  Reports whether the machine is configured for private features.

Public implementations:

- `AXWindowConstrainer`
- `OverlayReservationStrategy`

Private implementations:

- `DockInjectionWindowConstrainer`
- `DockOwnedReservationStrategy`

The public target links only public implementations.
The private target can compose different implementations in `AppEnvironment`.

## Runtime Shape

Use a separate environment branch:

- Public:
  `BarWindowController` + AX clamp + Dock preference control
- Private:
  `BarWindowController` + private helper bridge + optional AX fallback

The private bridge should be behind one facade:

- `PowerUserBridge`

Responsibilities:

- Detect whether private prerequisites are available.
- Establish IPC with helper components if needed.
- Expose high-level commands only.
- Never leak private API types into the shared UI layer.

## Helper Split

If private behavior requires injection into `Dock.app` or another privileged
system path, keep that out of the main app process.

Recommended split:

- `StartMenuPowerUser.app`
  UI, settings, diagnostics, feature toggles.
- `StartMenuPowerUserHelper`
  Opt-in component responsible for private communication or scripting
  addition orchestration.

The app should treat the helper as optional:

- If helper is unavailable, the app falls back to public behavior.
- If helper is connected, the app can enable experimental reservation or
  display-space behavior.

## Feature Flags

Use flags so experiments can be turned on independently:

- `powerUser.realDesktopReservation`
- `powerUser.privateMaximizeHandling`
- `powerUser.multiDisplayDockOwnership`
- `powerUser.debugOverlayMetrics`

Recommended rule:

- Compile flag decides whether the code exists.
- User default decides whether the feature is enabled.

## Diagnostics

The private build needs a separate diagnostics surface.

Add a debug panel that shows:

- helper connection status
- active reservation strategy
- current display and visible frame metrics
- private feature prerequisites
- last private bridge error

Keep logs separated:

- public subsystem:
  `app.pavlenko.startmenu`
- private subsystem:
  `app.pavlenko.startmenu.poweruser`

## Release Hygiene

Do not ship the private target through the same channel as the public app.

Guardrails:

- separate scheme
- separate artifacts folder
- separate Homebrew exclusion
- separate README section or standalone doc
- CI should fail if `PRIVATE_BUILD` symbols appear in the public target

## Migration Path

1. Extract current clamp logic behind `WindowConstraining`.
2. Add target-specific environment wiring.
3. Add private helper facade with a no-op implementation first.
4. Keep UI shared; swap only strategy objects.
5. Add diagnostics panel before enabling any private behavior by default.

## Why This Shape

This keeps the public app boring and supportable while still giving us a place
to experiment with Dock-owned or private window-server behavior. If the private
track breaks on a macOS update, the public app stays unaffected.
