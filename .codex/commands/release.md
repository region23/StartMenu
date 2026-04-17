---
description: Build changelog, commit, push, and publish a new StartMenu release
---

Release StartMenu end-to-end using `CHANGELOG.md` and `./scripts/release.sh`.

Workflow:
1. Treat `$ARGUMENTS` as the target version. If it is empty, inspect the latest existing release tag and propose the next patch version.
2. Find the latest release tag and inspect everything that would go into the release:
   - commits in `<latest_tag>..HEAD`
   - staged and unstaged local changes that will be included in the release commit
3. Draft a polished bilingual changelog entry from those changes. Write it in English and Russian, optimized for humans rather than raw commit logs.
4. Update `CHANGELOG.md` by prepending a new section in this format:

   ```md
   ## <version> - <YYYY-MM-DD>

   ### English
   - Bullet 1
   - Bullet 2

   ### Русский
   - Пункт 1
   - Пункт 2
   ```

5. Write the GitHub release body to `build/release/release-notes-<version>.md`. Use the same bilingual content, but start with `# Start Menu v<version>`.
6. Review `git status --short --branch`. If the tree contains unrelated changes that should not ship, stop and say exactly what needs to be stashed or split out. Otherwise stage the release-ready files, including `CHANGELOG.md`.
7. Commit the staged release-ready changes on `main` with the message `Prepare release v<version>`.
8. Push `main` to `origin`.
9. Run `./scripts/release.sh <version> --notes-file build/release/release-notes-<version>.md` from the repository root.
10. Report the release URL, the tag, whether the Homebrew tap update succeeded, and which files were committed.

Rules:
- Never modify or commit `.claude/settings.local.json`.
- Keep the changelog concise, release-note quality, and bilingual. English comes first, Russian second.
- Prefer short flat bullet lists. Add mini-headings only when they genuinely improve readability.
- Do not fabricate release notes. Base them on actual commits and diffs since the last release.
- If there are no unreleased changes, stop and explain that a new release would be a no-op unless the user explicitly wants a rebuild-only patch.
- Prefer the latest patch version when inferring a default version.
