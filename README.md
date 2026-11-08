# claude-homeostasis

Your body keeps itself at 37 °C without asking you. Your git repository has no reflex like that. This is the reflex.

```bash
homeostasis           # take its temperature
homeostasis --apply   # bring it back, carefully
```

---

## The worktree that was still warm

In September, our cleanup script looked at a git worktree and declared it finished. Nothing uncommitted. Nothing to lose. Safe to remove.

A Claude Code agent was working in it at the time.

The worktree was clean because the agent had only just arrived and hadn't written anything yet. To the script, a worktree where the work hasn't started looks exactly like one where the work is done. A person happened to read the report before running the cleanup. That is the only reason this paragraph is a story and not an apology.

That script is the ancestor of this one. Most of what makes this tool careful goes back to that day.

## How we got there

We build a fintech platform with a lot of help from Claude Code agents. Claude Code can give each agent its own git worktree, a separate checkout of the same repository, so ten agents can build ten things without bumping elbows. It works well. An agent arrives, builds, opens a pull request, and leaves.

"Leaves" is generous. The agent goes, but the worktree stays. So do its branch, its `node_modules`, and sometimes a test database it made for itself. Nobody notices, because looking is nobody's job.

In late August we looked. We found 379 worktrees taking up 59 GB of disk, and 306 of them belonged to pull requests that had merged and been forgotten.

Ten days later we looked again, more carefully:

- The main checkout, which every new session starts from, was sitting on a feature branch that had merged long before. Agents reading the code from there saw an older project and reported finished features as missing.
- 371 local branches had already been merged into `main`.
- 449 MB of folders were still on disk, although git no longer knew they existed.
- 42 test databases belonged to worktrees that were gone. Earlier that summer a stale one like them had sent us hunting for a bug in code that was fine.
- 25 screenshots and scratch files sat at the root of the repo, next to an empty file named `false`. Nobody has explained the file named `false`.

None of it was dramatic, and that was the trouble. Systems rarely break all at once. They drift a little at a time until somebody trips.

## What homeostasis means here

Homeostasis is the biologist's word for a living thing keeping itself steady. When you're too warm you sweat, and when you're too cold you shiver. Drifting is normal. Coming back is what matters.

A repository has a healthy resting state too:

- the main checkout is on `main`, and `main` is current
- nothing in it is half-edited or unexplained
- every worktree is either being used or gone
- branches that have merged are deleted
- nothing sits on disk that git has forgotten about

Agents push a repo away from that state all day long. That's their job. `homeostasis` measures how far the repo has drifted and moves back whatever can safely move back. Anything it can't be sure about, it leaves for you, along with the reason.

## A checkup

Here is part of a real report from a small demo repository:

```text
== 4. worktrees (excluding the primary)
   3 worktree(s): 1 REMOVABLE, 1 KEEP-DIRTY, 0 IN-USE, 1 INCONCLUSIVE, 0 PRUNABLE
   VIOLATION: 1 KEEP-DIRTY worktree(s) — a real edit, a gutted shell or a non-regenerable ignored path; a human decides, by name:
      ~/code/my-app/.claude/worktrees/login-page  [login-page]  1 status entries (1 real edits)
   VIOLATION: 1 INCONCLUSIVE worktree(s) — a read failed, or nothing here proves the work is finished; never removable until it does:
      ~/code/my-app/.claude/worktrees/agent-7  [agent-7]  no commit of its own beyond main — a worktree just created and one whose work has landed are indistinguishable here; a human decides
   VIOLATION: 1 REMOVABLE worktree(s) — --apply removes them (unforced; branch refs survive):
      ~/code/my-app/.claude/worktrees/fix-typo  [fix-typo]  clean, 1 commit(s) of its own beyond main

== 5. local branches merged into main
   VIOLATION: 1 merged branch(es) not attached to any worktree — --apply deletes them with git branch -d:
      old-feature
```

`agent-7` is the September story replayed. That worktree could be brand new or long finished, so the tool says it can't tell and leaves the call to you.

Every worktree gets exactly one of five answers:

| Answer | Meaning | What `--apply` does |
|---|---|---|
| **REMOVABLE** | clean, and its commits live on a branch that will survive | removes the folder; the branch stays |
| **KEEP-DIRTY** | real edits, or files that can't be regenerated | nothing; names it and says why |
| **IN-USE** | you're in it, it's locked, or it has an open pull request | nothing |
| **INCONCLUSIVE** | nothing proves the work there is finished | nothing; asks you |
| **PRUNABLE** | the folder is already gone; only git's record is left | prunes the record |

The full report also covers the main checkout, merged branches, `pr1234`-style scratch branches left behind by squash merges, folders git has forgotten, and (if you switch it on) orphaned test databases.

## Careful by design

Deleting a folder takes a second. The work in it may have taken a day. The tool is built around that.

- **It never forces anything.** If git refuses to remove a worktree, the refusal stands. It's the last safety check, and it gets the last word.
- **It never touches a file you changed or created.** It tells you where the file is and moves on.
- **"Couldn't check" never counts as "fine".** If `gh` is offline or a git command fails, the answer is INCONCLUSIVE, and nothing that depends on that answer gets removed.
- **Clean is not the same as finished.** A worktree must show positive evidence that work happened there and is safely stored somewhere else. An empty worktree proves nothing either way.
- **It looks again right before each removal.** The report you read a minute ago could already be out of date. Another agent may have moved in since.
- **It leaves detached worktrees alone.** A commit made in one and then abandoned is recorded only inside that folder, so removing the folder would erase it.

The complete rules, and the gaps we know about, are in [docs/how-it-works.md](docs/how-it-works.md).

## Setup

You need **git 2.23 or newer** and **bash 3.2 or newer** on the machine. Every Mac and every Linux box already has both.

Your login shell doesn't matter. The script starts with `#!/usr/bin/env bash`, so it runs the same way from zsh, bash, or fish. It's a single file with nothing to install, compile, or update.

### 1. Install

Pick one:

**Download it** (simplest):

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/vlad-ko/claude-homeostasis/main/homeostasis -o ~/.local/bin/homeostasis
chmod +x ~/.local/bin/homeostasis
```

**Clone and link it** (`git pull` keeps it up to date):

```sh
git clone https://github.com/vlad-ko/claude-homeostasis.git ~/src/claude-homeostasis
mkdir -p ~/.local/bin
ln -s ~/src/claude-homeostasis/homeostasis ~/.local/bin/homeostasis
```

**Commit it to your project** (your team and your agents get it with no install): copy `homeostasis` into something like `scripts/`, commit it, and run `scripts/homeostasis`.

### 2. Put `~/.local/bin` on your PATH

Skip this if `echo $PATH` already shows it.

| Shell | Run once |
|---|---|
| **zsh** (the macOS default) | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc` |
| **bash** on Linux | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc` |
| **bash** on macOS | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile && source ~/.bash_profile` |
| **fish** | `fish_add_path ~/.local/bin` |

### 3. Optional extras

- **See open pull requests:** install the [GitHub CLI](https://cli.github.com) and run `gh auth login`. Without it, `homeostasis` can't tell which branches have an open PR, so it plays safe and removes fewer worktrees.
- **Claude Code users:** nothing to do. Agent worktrees under `.claude/worktrees/` are checked as worktrees, and they won't show up as stray files in your main checkout, whether or not that folder is gitignored. Anything else left lying around in there still gets reported.

**Where it runs:** macOS and Linux, both tested in CI. On Windows, use WSL, where it behaves like Linux. Native Windows shells aren't tested.

## Everyday use

```bash
homeostasis           # same as --check
homeostasis --check   # report only. Exit 0 = healthy, 1 = drifted
homeostasis --apply   # do the safe part, then report again
homeostasis --help
```

Run it from anywhere inside a repository, including from inside one of its worktrees.

**Your first time:** run it and read the report. Each section either says `(ok)` or lists exactly what drifted. Items marked REMOVABLE are what `--apply` would clean. Anything marked KEEP-DIRTY or INCONCLUSIVE is your decision, and the report explains each one. Once the list looks right, run `--apply`.

**Teach your agents.** Add a line like this to your `CLAUDE.md`:

> Before you finish a task, run `homeostasis --check` and include the result. Never run `--apply` without showing me the report first.

## Configuration

Most repos need no configuration. If yours does, set environment variables, or put `KEY=value` lines in a `.homeostasis` file at the repo root. The file is read as plain data and never executed. An unknown key gets a warning, and an invalid value stops the run before anything is touched.

| Key | Default | What it does |
|---|---|---|
| `HOMEOSTASIS_MAIN_BRANCH` | read from `origin/HEAD`, otherwise `main` | the branch everything else is measured against |
| `HOMEOSTASIS_REMOTE` | `origin` | the remote to fetch from |
| `HOMEOSTASIS_WORKTREES_DIR` | `.claude/worktrees` | where to look for folders git has forgotten (empty turns this off) |
| `HOMEOSTASIS_REGENERABLE` | `node_modules vendor .venv target dist build` and similar | ignored folders that are safe to lose because a reinstall rebuilds them |
| `HOMEOSTASIS_GH` | `auto` | set to `off` to skip GitHub lookups |
| `HOMEOSTASIS_TRUST_NO_PRS` | unset | `1` on repos that don't use GitHub PRs: treats "no PR information" as "no open PRs", and says so loudly |
| `HOMEOSTASIS_MYSQL_CONTAINER` | unset (check off) | the Docker container that holds per-worktree test databases |
| `HOMEOSTASIS_SCHEMA_PREFIX` | `testing` | those databases are named `<prefix>_<worktree-name>` |

Commit `.homeostasis` so your whole team shares it. If you don't, list it in `.git/info/exclude`, or the tool will report it as a stray file.

`.env` is not on the regenerable list, because a `.env` usually holds secrets that nothing can rebuild. If your setup script does recreate it, add it. See [`.homeostasis.example`](.homeostasis.example).

## Tests

```bash
test/run.sh
```

There are 198 checks. They build throwaway repositories and stand in for `gh` and `docker`, so nothing real is touched. CI runs them on Linux and macOS.

## License

MIT. Built for a fintech platform, where it keeps a busy fleet of agents in balance. Shared because yours probably drift too.
