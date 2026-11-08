# How claude-homeostasis works

**The rule: every task ends on a clean slate, and the primary checkout is the slate.** Work
happens in worktrees; the primary checkout is the baseline every session — human or agent —
starts from, so it is left exactly as a fresh clone would be: on the main branch, at
`<remote>/<main>`, with nothing modified, nothing untracked, no worktree of finished work, no
merged local branch, no leftover worktree directory git has forgotten, and (optionally) no test
database whose worktree is gone.

`homeostasis --check` reports every deviation. `homeostasis --apply` removes the subset that can
be removed with **no possibility of losing work**, then checks again. Everything else is surfaced
by name for a human to decide.

The authoritative wording of every rule below is the header comment of the `homeostasis` script.

## Why drift matters

- **Stale-main reads.** Anyone — or any agent — reading code from a primary that sits on an old
  feature branch, or behind the remote, reports merged work as absent and duplicates it.
- **Wrong merge bases.** A rebase or conflict resolution done against a stale primary resolves
  against the wrong base.
- **Leftover per-worktree databases** fall out of step with the schema and produce test failures
  that look like code regressions.
- **Disk and attention.** Parallel agents create worktrees fast. Without a sweep, hundreds of
  them (tens of GB) accumulate, along with hundreds of merged branches, stray screenshots at the
  repo root, and directories git no longer even lists.

## The checks

| # | Check | Violation when | `--apply` does |
|---|-------|----------------|----------------|
| 1 | Primary branch and freshness | primary not on main, detached, behind or ahead of `<remote>/<main>` after `git fetch`; a failed fetch is INCONCLUSIVE | nothing (never checks out, resets or merges) |
| 2 | Modified tracked files in the primary | any | nothing |
| 3 | Untracked paths in the primary | any | nothing |
| 4 | Non-primary worktrees | REMOVABLE, KEEP-DIRTY, INCONCLUSIVE or PRUNABLE | unforced `git worktree remove` on REMOVABLE, `git worktree prune` |
| 5 | Local branches merged into main | any (attached to a worktree or not) | `git branch -d` on unattached ones |
| 5b | `pr<N>` scratch branches (needs `gh`) | GitHub merged exactly this tip, or the read failed, or the tip diverged | `git branch -D` only on "merged at exactly this tip" |
| 6 | Debris directories under `HOMEOSTASIS_WORKTREES_DIR` | any directory git does not register | `rm -rf` only when it holds no `.git` and only regenerable content |
| 7 | Orphan test schemas (opt-in) | a `<prefix>_<worktree>` schema with no worktree | `DROP DATABASE` on recognised orphans |

## Classifying a worktree

Tests run in this order; the first that matches decides.

| Class | Meaning | Removed by `--apply`? |
|-------|---------|-----------------------|
| PRUNABLE | its directory is gone | the stale record is pruned |
| IN-USE | the worktree you are running from, a `locked` worktree, or a branch with an open PR | never |
| INCONCLUSIVE | a read failed, or nothing proves the work is finished: no commit of its own, a DETACHED HEAD, or local main BEHIND the freshly fetched remote | never |
| KEEP-DIRTY | a modification, an untracked file, a gutted shell (only deletions), or an ignored file outside the regenerable allowlist | never |
| REMOVABLE | clean, every ignored path regenerable, on a branch with at least one commit a proven-current main does not have | yes, unforced |

Four properties worth knowing:

- **Removal is earned by positive evidence, never by the absence of a sign of life.** A clean
  worktree whose branch is contained in main is true of a worktree created seconds ago (an agent
  is about to build in it) *and* of one whose work has landed. Opposite states, one key, so it is
  INCONCLUSIVE. In a squash-merging repository a finished branch still carries its own commits, so
  this costs nothing in the normal case.
- **A detached worktree is never removable, even at zero commits.** `git rev-list main..HEAD`
  answers "is HEAD's history in main", not "did this worktree ever produce a commit". A commit
  made in a detached worktree and then abandoned is recorded only in that worktree's own
  `logs/HEAD`, which `git worktree remove` deletes. On a branch, that reflog lives in the common
  git dir and survives. The pristine-tree pattern `git worktree add --detach <path> origin/main`
  therefore stays INCONCLUSIVE until you remove it yourself; the report prints the command.
- **A count is only as good as its baseline.** The script fetches the remote but never advances
  local main. While local main is behind, a worktree created from the newer tip inherits upstream
  commits that would read as its own, so no count is believed at all and nothing is removed. The
  report prints the `git merge --ff-only` command that fixes it.
- **No answer is never an answer.** A failed `git worktree list`, `git branch --merged`,
  `git status`, `git rev-list` or `docker exec ... mysql` is reported as INCONCLUSIVE — a
  violation — never as "none (ok)" or zero, and `--apply` performs nothing that depends on it.
  An empty `gh` result means "no open PRs" only when `gh` exited 0 and the result was below its
  500-PR ceiling.

## The regenerable allowlist

`git status --porcelain` without `--ignored` never lists ignored files, so a worktree holding
only a gitignored `.env` looks clean — and `git worktree remove` deletes it without a word.
homeostasis reads ignored files too, and a worktree is removable only when every ignored path is
on `HOMEOSTASIS_REGENERABLE` (is one of the entries, lies under one, or is the bare parent of a
nested one). The default is conservative — dependency directories, build output and tool caches:

```
node_modules vendor .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox target
dist build .next .nuxt .turbo .parcel-cache coverage .gradle .phpunit.cache
.phpunit.result.cache .phpstan-cache
```

`.env` is deliberately absent: secrets are not regenerable in general. If your worktree setup
recreates `.env` from a template, add it yourself. Anything else ignored — `notes.txt`, a
`.env.bak`, a local dump — makes the worktree KEEP-DIRTY, surfaced with its path.

## Debris directories

A `git worktree remove` that aborted halfway (or a directory whose `.git` file was lost) leaves a
physical directory `git worktree list` cannot see. homeostasis lists every directory directly
under `HOMEOSTASIS_WORKTREES_DIR` (default `.claude/worktrees`, Claude Code's agent worktree
location) that git does not register. `--apply` removes one only when it has no `.git` entry and
holds nothing but regenerable paths plus top-level `*.json` scratch. Anything source-shaped is
surfaced with the first offending path.

## `pr<N>` scratch branches

Reading a PR's head locally (`git fetch origin pull/42/head:pr42`) leaves branches named `pr42`,
`pr-42-review`, `pr42-tmp`. In a squash-merging repository they are never ancestors of main, so
check 5 never sees them as merged and they pile up. homeostasis asks `gh pr view <N> --json
state,headRefOid` and deletes (`-D`) only when the PR is MERGED **and** the local tip equals the
commit GitHub merged. The name alone is not a license: an unrelated branch that happens to share
the name, or a scratch branch that gained commits after the merge, comes back DIVERGED and is
surfaced. OPEN and CLOSED PRs' branches are not reported or touched at all. Without `gh` the
section is skipped.

## Orphan test schemas (opt-in)

Enabled only when `HOMEOSTASIS_MYSQL_CONTAINER` is set. It assumes one convention: a per-worktree
setup creates a MySQL database named `<prefix>_<basename>`, where `<basename>` is the worktree
directory's basename with every character outside `[A-Za-z0-9]` replaced by `_`
(`tr -c 'A-Za-z0-9' '_'`); the prefix is `HOMEOSTASIS_SCHEMA_PREFIX` (default `testing`). Schemas
are read via `docker exec <container> mysql` using the container's own `MYSQL_ROOT_PASSWORD`
(the official image's variable), which never leaves the container.

A schema is an orphan when its name maps to no registered worktree, no directory under the
worktree parent, not the primary's own derived name, and not a `DB_DATABASE=` in the primary's
`.env` / `.env.testing`. The base `<prefix>` schema is never dropped; a name outside
`<prefix>_[A-Za-z0-9_]+` is surfaced, never dropped. If any worktree name would exceed MySQL's
64-character identifier limit once prefixed, your setup must be shortening it somehow, and that
mapping is not guessed: the whole check refuses (INCONCLUSIVE) rather than risk a wrong `DROP`.

## Without GitHub

PR awareness is what lets homeostasis tell "finished" from "open for review". With `gh` missing
or `HOMEOSTASIS_GH=off`, every worktree that is not locked or in use is INCONCLUSIVE and nothing is
removed — the safe default. For a repository that does not use pull requests at all, set
`HOMEOSTASIS_TRUST_NO_PRS=1`: "no PR information" is then treated as "no open PRs", and a loud
banner is printed on every run while it is on. Lock (`git worktree lock`) any worktree that must
survive.

## What `--apply` will never do

- pass `--force` to `git worktree remove` — git's own refusal of a dirty tree is the last check
  before the delete, and forcing re-opens exactly the window that refusal closes;
- touch a modified or untracked file, in the primary or in any worktree;
- remove a KEEP-DIRTY, IN-USE or INCONCLUSIVE worktree, or a DETACHED one;
- check out, reset, merge, or fetch anything beyond `git fetch <remote> <main>`;
- delete an unmerged branch with `-D` unless GitHub confirms it merged exactly that tip;
- drop the base test schema, or any schema whose name it does not recognise;
- act on a read that failed;
- trust its own earlier report: every removal re-classifies the target immediately before it runs.

It may be run from any checkout. The worktree containing your current directory (and the one
containing the script, if it lives inside the repository) is IN-USE by definition, and every git
call after startup is `-C <primary>`, so nothing depends on the caller's directory surviving.

## Residual gaps, stated honestly

- `git worktree remove` checks the tree and deletes it inside one git process. That window is
  git's, not this tool's, and is the narrowest available.
- The ignored-path allowlist is checked by homeostasis only — git does not consider ignored files
  dirty — so an ignored, non-regenerable file created *between* the classification and the remove
  is lost. Lock a worktree (`git worktree lock`) to close even that window: a locked worktree is
  IN-USE.
- The `.homeostasis` file is repository content. It is parsed safely (never sourced, allowlisted
  keys, validated values that cannot escape the repository), but a repository you do not trust
  can still widen `HOMEOSTASIS_REGENERABLE` for itself. Review it like any other config.
- This is a check-and-apply tool, not an enforcement mechanism. Nothing makes a session run it;
  wiring it into a session-end hook or CI is up to you.

## Requirements

bash 3.2+ (macOS `/bin/bash` works), git 2.23+ (for `%(worktreepath)`; an older git is refused
at startup), and POSIX utilities (`sed`, `grep`, `find`, `tr`, `cut`, `sort`, `basename`,
`dirname`). `gh` and `docker` are optional; without them the dependent checks degrade to
INCONCLUSIVE or skipped, never to a crash.
