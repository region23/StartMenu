# Changelog

This changelog is maintained in English and Russian by the local `/release`
command.

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
