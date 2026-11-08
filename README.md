# claude-homeostasis

**Your repo is messier than you think. This tells you how messy, and cleans up the parts that are safe to clean.**

```bash
homeostasis           # look (changes nothing)
homeostasis --apply   # tidy the safe stuff, then look again
```

---

## Wait, what's "homeostasis"?

It's the word biologists use for a body keeping itself in balance. You sweat when you're hot and shiver when you're cold. Nobody has to think about it. Your body notices it has drifted and quietly puts itself back.

Your git repo has no such reflex. It only drifts, and nothing ever puts it back. This tool is the reflex.

## The problem, explained like you're five

Imagine you share a toy room with a bunch of very fast, very helpful robots. Each robot grabs a table, builds something, and leaves. None of them puts the blocks back.

After a week:

- the table **you** sit at has someone else's half-built castle on it,
- there are 300 tables nobody uses anymore, and each one still has blocks on it,
- some tables vanished from the floor plan but somehow still take up space,
- and the toy-box labels say "castle (finished)" on about 400 boxes.

You never see any of this, because you only ever look at your own table. Then one day your table is wobbly, and you can't work out why.

**The robots are AI coding agents. The tables are git worktrees.** The mess is real: it fills your disk, slows your machine, and sometimes gives your next agent a wrong picture of the code.

## What it checks

| # | Check | What "dirty" looks like |
|---|---|---|
| 1 | Your main checkout is on `main`, up to date with `origin/main` | you're parked on a feature branch that merged three weeks ago |
| 2 | No modified files in the main checkout | `config.yml` has been edited and nobody remembers why |
| 3 | No untracked files in the main checkout | 25 screenshots and an empty file named `false` |
| 4 | Every worktree, sorted into five buckets (see below) | 300 worktrees for PRs that already merged |
| 5 | No local branches already merged into `main` | 371 of them |
| 5b | No `pr1234`-style scratch branches whose PR was squash-merged | the ones `git branch --merged` can't see, ever |
| 6 | No "debris" folders git has forgotten about | half-deleted worktrees that `git worktree list` doesn't show |
| 7 | *(optional)* No orphaned per-worktree test databases | test schemas whose worktree is long gone |

Every worktree ends up in exactly one bucket:

- **REMOVABLE**: clean, with its own commits safely stored on a branch. `--apply` will remove it.
- **KEEP-DIRTY**: has real edits or files that can't be regenerated. Never touched. You get its name and the reason.
- **IN-USE**: you're running from it, it's locked, or it has an open PR. Left alone.
- **INCONCLUSIVE**: the tool can't *prove* the work there is done, so it doesn't guess. It asks you.
- **PRUNABLE**: the folder is already gone and only git's bookkeeping is left. Pruned.

## The paranoid part (the part we're proudest of)

A cleanup tool that deletes your work is worse than no cleanup tool at all. So:

- **It never uses `--force`.** If git refuses to remove a worktree, that refusal is the final safety check, and we respect it.
- **It never touches a modified or untracked file.** Ever. It names them and moves on.
- **A failed read is never "ok".** If `gh` is offline, or `git status` errors, or the database container is down, the answer is **INCONCLUSIVE** and nothing gets removed. "I couldn't check" and "there's nothing there" are different answers, and the tool keeps them apart.
- **A clean folder is not proof of finished work.** A worktree an agent created *five seconds ago* looks exactly like one whose work merged last week. A worktree is removable only on *positive* evidence: it has commits of its own, held by a branch that outlives the folder.
- **It re-checks right before every delete.** The report you read a minute ago isn't trusted, because another agent may have started using that worktree since.
- **Detached worktrees are never auto-removed.** A commit made there and then abandoned lives only in that worktree's own log, and removing the folder would erase it.

The full rules and the gaps we know about are in [docs/how-it-works.md](docs/how-it-works.md).

## Why we built this (a true story)

We build a production fintech platform with a fleet of **Claude Code agents** working side by side. Claude Code can give each agent its own git worktree, so ten of them can build ten features at once without stepping on each other. It's great. It's also how we buried ourselves.

Every agent made a worktree, did its job, opened a PR, and moved on. The PRs merged. The worktrees didn't go anywhere. Neither did the branches, the `node_modules`, the `vendor/` folders, or the test databases each agent spun up.

Nobody noticed, because nobody ever looks at *all* of it at once. Then one day we did:

- **379 worktrees eating 59 GB**, and 306 of them belonged to PRs that had already merged.
- **371 local branches** that had already merged into `main`.
- The main checkout was **parked on a feature branch that had merged weeks earlier**. Any agent reading the code from there saw an old world and reported finished work as *missing*.
- **25 stray screenshots and scratch files** at the repo root, plus an empty file literally named `false`. Nobody ever owned up to that one.
- **449 MB of "ghost" worktree folders** that git no longer knew about, and **42 orphaned test databases** whose worktrees were long gone. A stale one of those once made tests fail, and we went hunting for a code bug that didn't exist.

So we wrote a script to clean it up, and the first version nearly ate live work. It flagged a worktree as "clean, safe to remove" **while an agent was actively building in it**. A human spotted it before `--apply` ran. That near-miss is why the tool is now so paranoid. Every rule in the list above comes from something that went wrong, or almost did.

Now it runs at the end of every agent session, and the slate starts clean every time.

## Setup (about 60 seconds)

**What you need:** `bash` and `git`. That's all. It's one bash script with nothing to install, nothing to compile, and no package manager.

| Tool | Needed? | Why |
|---|---|---|
| bash 3.2+ | **yes** | the old bash that ships with macOS is fine |
| git 2.23+ | **yes** | `git --version` to check |
| [`gh`](https://cli.github.com) | optional | lets it see which branches have open PRs. Without it, PR-dependent answers stay INCONCLUSIVE (safe, but less cleanup) |
| docker | optional | only if you turn on the test-database check |

**1. Drop the script on your PATH:**

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/vlad-ko/claude-homeostasis/main/homeostasis -o ~/.local/bin/homeostasis
chmod +x ~/.local/bin/homeostasis
```

(No `~/.local/bin` on your PATH? Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile. Or just clone this repo and run `./homeostasis` from it.)

**2. (Optional) Let it see your PRs:** `gh auth login`

**3. Run it from inside any repo** (or any of its worktrees):

```bash
cd ~/code/my-project
homeostasis
```

That's it. It changes nothing until you say `--apply`.

### Your first run

1. Run `homeostasis` and read the report. Each section says `(ok)` or lists `VIOLATION:` lines that name every item.
2. **REMOVABLE** items are what `--apply` would clean. **KEEP-DIRTY** and **INCONCLUSIVE** items are for you to decide. The report says why for each one.
3. Happy with it? Run `homeostasis --apply`. It cleans the safe set and prints the report again.
4. Anything it left behind is yours to decide. It's left on purpose.

## Use

```bash
homeostasis --check   # report only; exit 0 = clean, 1 = something to look at
homeostasis --apply   # do ONLY the safe actions, then re-check
homeostasis --help
```

**Tip for Claude Code users:** add a line like this to your `CLAUDE.md` so your agents clean up after themselves:

> Before ending a task, run `homeostasis --check` and report the verdict. Never run `--apply` without showing me the report first.

## Configure (optional)

Put a `.homeostasis` file in your repo root, or set environment variables. The file is plain `KEY=value` lines. It's parsed, never executed, and unknown keys are ignored with a warning.

| Key | Default | What it does |
|---|---|---|
| `HOMEOSTASIS_MAIN_BRANCH` | auto-detected from `origin/HEAD`, else `main` | the branch everything is measured against |
| `HOMEOSTASIS_REMOTE` | `origin` | the remote to fetch from |
| `HOMEOSTASIS_WORKTREES_DIR` | `.claude/worktrees` | where to look for ghost folders (empty = skip) |
| `HOMEOSTASIS_REGENERABLE` | `node_modules vendor .venv target dist build` … | ignored paths that are safe to lose because a reinstall brings them back |
| `HOMEOSTASIS_GH` | `auto` | `off` to skip GitHub lookups |
| `HOMEOSTASIS_TRUST_NO_PRS` | unset | `1` = no GitHub, so treat "no PR info" as "no open PRs" (prints a loud warning) |
| `HOMEOSTASIS_MYSQL_CONTAINER` | unset (check off) | Docker container holding per-worktree test schemas |
| `HOMEOSTASIS_SCHEMA_PREFIX` | `testing` | schemas named `<prefix>_<worktree-name>` |

Commit `.homeostasis` with your repo so the whole team shares it. Otherwise list it in `.git/info/exclude`, or it will show up as an untracked file, which is exactly what this tool complains about.

`.env` is **not** in the regenerable list by default, because a `.env` usually holds secrets you can't just regenerate. If your setup script rebuilds it, add it. See [`.homeostasis.example`](.homeostasis.example).

## Tests

```bash
test/run.sh
```

Each test builds throwaway repos, stubs out `gh` and `docker`, and touches nothing real. CI runs the tests on Linux and macOS.

## License

MIT. Built for a fintech platform, where it keeps our agents tidy, and shared because your agents probably need it too.
