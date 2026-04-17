# Changelog

This changelog is maintained in English and Russian by the local `/release`
command.

## 0.3.26 - 2026-04-17

### English
- Fixed VS Code window titles in the bar hover popup: when multiple Code windows are open, the popup now preserves the project or folder names instead of showing every row as just `Code`.
- Added a geometry-based Accessibility fallback in `WindowService` so AX window titles can still be matched back to CG windows when Electron apps do not expose a direct `CGWindowID` bridge.

### Русский
- Исправили заголовки окон VS Code во всплывающем popup бара: если открыто несколько окон Code, popup теперь показывает названия проектов и папок, а не две одинаковые строки `Code`.
- Добавили geometry-based fallback в `WindowService`: теперь AX-заголовки можно сопоставить с CG-окнами даже в тех случаях, когда Electron-приложение не отдаёт прямую привязку к `CGWindowID`.

## 0.3.25 - 2026-04-17

### English
- Fixed the severe performance regression that appeared after `0.3.22`: timer refreshes no longer re-query the full running-app list on every tick, and the Menu Bar Items scanner no longer performs background Accessibility polling while idle.
- Reduced bar and Start Menu hitching by reusing the performance trace file handle, throttling background refresh work during live interactions, and avoiding redundant cursor-rect invalidation during chip animations.
- Cut window constrainer overhead by passing the current regular app PID list directly from `WindowService` instead of rescanning `NSWorkspace` inside every constraint refresh.

### Русский
- Исправили тяжёлую performance-регрессию, появившуюся после `0.3.22`: timer-refresh больше не перечитывает полный список запущенных приложений на каждом тике, а сканер Menu Bar Items больше не делает фоновый Accessibility polling в простое.
- Уменьшили лаги бара и Start Menu: trace-лог теперь пишет через переиспользуемый file handle, фоновый refresh сильнее прижимается во время живых взаимодействий, а у анимаций чипсов убрали лишнюю инвалидизацию cursor rects.
- Снизили стоимость window constrainer: `WindowService` теперь передаёт в него актуальный список regular PID'ов напрямую, без повторного сканирования `NSWorkspace` на каждом constraint-refresh.

## 0.3.24 - 2026-04-17

### English
- Added built-in performance diagnostics: the app now writes local trace logs for slow operations and main-thread stalls, with controls in Settings to reveal, copy, or clear the log file.
- Reduced UI hitching by moving heavy window snapshot rebuilding off the main thread, coalescing overlapping refreshes, and easing how often window constraining runs.

### Русский
- Добавили встроенную performance-диагностику: приложение теперь пишет локальный trace-лог медленных операций и подвисаний main thread, а в Settings появились кнопки открыть, скопировать путь или очистить лог.
- Уменьшили подлагивания интерфейса: тяжёлую пересборку снапшотов окон вынесли с main thread, overlapping refresh'и теперь коалессятся, а window constraining выполняется мягче и реже.

## 0.3.23 - 2026-04-17

### English
- Fixed the Trash button icon so it now refreshes to the full system Trash artwork when files are present.
- Removed the cached Trash icon fallback that could leave the bar stuck showing the empty icon.

### Русский
- Исправили иконку корзины: теперь при наличии файлов она корректно переключается на системное состояние полной корзины.
- Убрали кэшированный fallback для иконки Trash, из-за которого бар мог залипать на пустой корзине.

## 0.3.22 - 2026-04-17

### English
- Fixed the Trash button state so the bar no longer shows an empty Trash icon when the user's Trash still contains files.
- Trash contents are now detected without filtering out real trashed items as hidden files.

### Русский
- Исправили состояние кнопки корзины: бар больше не показывает пустую корзину, когда в пользовательской Trash ещё есть файлы.
- Проверка содержимого корзины теперь не отфильтровывает реальные удалённые файлы как скрытые элементы.

## 0.3.21 - 2026-04-17

### English
- Replaced the custom Trash folder icon in the bar with the native macOS Trash artwork.
- The Trash button now switches between the empty and full system icons based on the actual contents of the user's Trash.

### Русский
- Заменили кастомную иконку папки у корзины в баре на нативную системную иконку macOS Trash.
- Кнопка корзины теперь переключается между системными состояниями пустой и полной корзины по реальному содержимому пользовательской Trash.

## 0.3.20 - 2026-04-17

### English
- Added a Trash button to the right side of the bar, just before Menu Bar Items, using the native Trash icon and opening the Trash in Finder on click.
- Refined the pinned-app divider to look closer to the macOS Dock with a taller, thinner separator and a softer highlight.
- Restyled the multi-window hover popup to match the calmer Start Menu and Menu Bar Items selection look instead of using blue-highlighted rows.

### Русский
- Добавили кнопку корзины в правую часть бара, сразу перед Menu Bar Items: используется нативная иконка Trash, а по нажатию открывается корзина в Finder.
- Доработали разделитель у закрепленных приложений, чтобы он был ближе к стилю системного Dock: выше, тоньше и с более мягким бликом.
- Привели popup со списком окон одного приложения к более спокойному стилю Start Menu и Menu Bar Items, без синего выделения строк.

## 0.3.19 - 2026-04-17

### English
- Made the pinned-app area easier to read by adding a clearer visual divider between pinned icons and regular running app chips.
- Upgraded the local `/release` workflow to generate polished bilingual release notes, update `CHANGELOG.md`, commit and push `main`, and publish GitHub and Homebrew releases from one flow.
- Added support for publishing custom Markdown release notes via `./scripts/release.sh --notes-file`.

### Русский
- Сделали зону закрепленных приложений заметнее: между pinned-иконками и обычными чипсами появился более явный визуальный разделитель.
- Улучшили локальную команду `/release`: теперь она может собирать аккуратные двуязычные release notes, обновлять `CHANGELOG.md`, коммитить и пушить `main`, а затем публиковать релиз в GitHub и Homebrew.
- Добавили в `./scripts/release.sh` поддержку публикации кастомных Markdown release notes через `--notes-file`.

Releases up to `v0.3.18` used GitHub-generated release notes. For older
versions, see the GitHub Releases page:
https://github.com/region23/StartMenu/releases
