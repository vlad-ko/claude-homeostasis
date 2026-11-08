# Changelog

All notable changes to claude-homeostasis are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-07

### Added

- `homeostasis --check` / `--apply`: a bash 3.2-portable report (and safe
  cleanup) of a git repository's drift — primary checkout not on a fresh main
  branch, modified or untracked files in the primary, stale worktrees
  (PRUNABLE / IN-USE / INCONCLUSIVE / REMOVABLE / KEEP-DIRTY), merged local
  branches, squash-merged `pr<N>` scratch branches, debris directories git no
  longer registers, and orphan per-worktree MySQL test schemas.
- Safety invariants: never `--force`; never touches modified or untracked
  files; a failed read is INCONCLUSIVE, never "ok"; every removal is
  re-classified immediately before it runs; a worktree is removable only on
  positive evidence (a branch carrying its own commits against a proven-current
  main); detached worktrees are never removable.
- Configuration via environment variables or a parsed (never sourced)
  `.homeostasis` file: `HOMEOSTASIS_MAIN_BRANCH` (auto-detected from
  `<remote>/HEAD`), `HOMEOSTASIS_REMOTE`, `HOMEOSTASIS_WORKTREES_DIR`,
  `HOMEOSTASIS_REGENERABLE`, `HOMEOSTASIS_MYSQL_CONTAINER`,
  `HOMEOSTASIS_SCHEMA_PREFIX`, `HOMEOSTASIS_GH`, `HOMEOSTASIS_TRUST_NO_PRS`.
- `--help`, `--version`; exit codes 0 / 1 / 2; colour on a TTY, `NO_COLOR`
  respected.
- `test/run.sh`: a self-contained harness (scratch repositories, stubbed `gh`
  and `docker`, no network) and a CI workflow running it with shellcheck on
  Linux and macOS.

[0.1.0]: https://github.com/vlad-ko/claude-homeostasis/releases/tag/v0.1.0
