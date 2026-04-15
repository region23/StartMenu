---
description: Build and publish a new StartMenu release
---

Release StartMenu using `./scripts/release.sh`.

Steps:
1. Treat `$ARGUMENTS` as the version string. If it is empty, inspect the latest existing release tag and propose the next patch version.
2. Check `git status --short --branch` and make sure the working tree is clean except for `.claude/settings.local.json`.
3. Review the current uncommitted changes and summarize what will go into the release.
4. Run the project build if needed to catch obvious issues before cutting the release.
5. Run `./scripts/release.sh <version>` from the repository root.
6. Report the release URL and mention whether the Homebrew tap update succeeded.

Rules:
- Never modify or commit `.claude/settings.local.json`.
- If the tree is dirty, stop and explain exactly which files need to be committed or stashed first.
- Prefer the latest patch version when inferring a default version.
