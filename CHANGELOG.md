# Changelog

This changelog is maintained in English and Russian by the local `/release`
command.

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
