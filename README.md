# claude-homeostasis

**A reflex for repositories that AI agents live in.**

Your body holds itself at 37 °C without ever consulting you. Run a little warm and you sweat; catch a chill and you shiver; and all the while you get on with your day, blissfully unaware of the paperwork. A git repository has no such reflex. Fill it with busy coding agents and it drifts, quietly and politely, one forgotten worktree at a time, until the disk is full and the main checkout is living in the past.

`homeostasis` is the reflex it was missing.

```bash
homeostasis           # take its temperature
homeostasis --apply   # bring it home, carefully
```

---

## The worktree that was still warm

In September, our cleanup script looked at a git worktree, found nothing uncommitted, and pronounced it dead.

A Claude Code agent was working inside it at the time.

The agent hadn't written anything yet. It had only just moved in, and an empty room looks exactly the same whether someone has just arrived or just left. The script couldn't tell the difference. A human happened to read the report before pressing the button, which is the only reason this paragraph is an anecdote and not a post-mortem.

Everything careful about this tool descends from that near miss.

## How we got there

We build a fintech platform with a lot of help from Claude Code agents. Each agent gets its own git worktree, a private checkout of the same repository, so ten of them can build ten things at once without stepping on each other's toes. It's a lovely arrangement. An agent moves in, does the work, opens a pull request, and moves on.

What it doesn't do is pack. The worktree stays behind, and so do the branch, the `node_modules`, and now and then a test database the agent spun up for itself. Noticing any of this is nobody's job, so nobody does.

In late August, somebody finally did. We counted 379 worktrees holding 59 GB of disk, and 306 of them belonged to pull requests that had merged and been forgotten.

That was the attic. Ten days later we searched the rest of the house:

- **The front door was stuck in the past.** The main checkout, where every new session starts, was parked on a feature branch that had merged long before. Agents reading the code from there saw a younger project, and dutifully reported finished features as missing.
- **371 local branches** had merged into `main` and simply never left.
- **449 MB of folders** sat on disk that git no longer remembered creating.
- **42 test databases** had outlived the worktrees that made them. Earlier that summer, one just like them sent us chasing a bug through code that was perfectly fine.
- **25 screenshots and scratch files** lay around the repo root, beside an empty file named `false`. To this day, nobody has owned up to `false`.

Nothing broke. Everything drifted. That is the trouble with drift: no single step is ever alarming, so nobody sounds the alarm, right up until someone trips over the result.

## What homeostasis means here

Homeostasis is the biologist's word for how a living thing stays itself in a changing world. It was never about standing still; your temperature wanders all day long. It's about always finding the way back.

A repository has a resting state worth finding the way back to:

- the main checkout is on `main`, and `main` is current
- nothing in it is half-edited or unexplained
- every worktree is either in use or gone
- merged branches are deleted
- nothing sits on disk that git has forgotten about

Agents push a repo away from that state all day long. That isn't a flaw; it's the job. The trouble starts when nothing pushes back. `homeostasis` is the pushing back: it measures how far the repo has drifted, returns whatever can safely be returned, and hands you the rest with a note explaining why.

## Why not just `git worktree prune`?

Because `prune` only forgets folders that are already gone, `git branch -d` only knows about branches, and `rm -rf` knows nothing at all. None of them can answer the one question that matters once agents share your repository:

> *Is anyone still working here, and is the work safe somewhere else?*

`homeostasis` asks that question of every worktree, checks the answer against git and (if you have it) GitHub, and acts only when the evidence is in. It's less a broom than a doctor: it examines first, explains what it found, and treats only what it's sure about.

## Why not just ask Claude to clean up?

You can. That's how the mess got made.

Ask an agent to tidy up and it tidies to its own idea of tidy, which changes from one session to the next. One day it keeps 50 GB of test databases, because someone might need them. The next day it removes a worktree because it looks clean, while another agent is still working inside it. Neither choice is lazy. Both are judgment calls, and judgment is a poor place to keep a definition.

`homeostasis` writes the definition down: one resting state, the same rules on every run, and the evidence printed beside every decision. The agent no longer decides what clean means. It only has to ask. Our everyday flow is one sentence to Claude:

> Bring my local back to homeostasis.

Claude runs the check, shows the report, applies the safe part, and hands back the decisions that were always yours. Its intelligence goes into reading the report, not into rewriting the rules.

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

`agent-7` is September all over again: a worktree that could be brand new or long finished. Rather than guess, the tool says so out loud and leaves the decision with you.

Every worktree leaves the exam with exactly one diagnosis:

| Diagnosis | Meaning | What `--apply` does |
|---|---|---|
| **REMOVABLE** | clean, and its commits live on a branch that will survive | removes the folder; the branch stays |
| **KEEP-DIRTY** | real edits, or files that can't be regenerated | nothing; names it and says why |
| **IN-USE** | you're in it, it's locked, or it has an open pull request | nothing |
| **INCONCLUSIVE** | nothing proves the work there is finished | nothing; asks you |
| **PRUNABLE** | the folder is already gone; only git's record is left | prunes the record |

The full report also covers the main checkout, merged branches, `pr1234`-style scratch branches left behind by squash merges, folders git has forgotten, and (if you switch it on) orphaned test databases.

## Careful by design

Deleting a folder takes a second. The work inside it may have taken a day. Every rule below exists because of that imbalance.

- **It never forces.** If git refuses to remove a worktree, the refusal stands. Git is the last safety net, so git gets the last word.
- **It never touches what you made.** A file you changed or created is reported by name and left exactly where it is.
- **"Couldn't check" never means "fine."** If `gh` is offline or a git command fails, the answer is INCONCLUSIVE, and nothing that depends on it is removed.
- **Clean is not finished.** A worktree must show positive evidence that work happened and is stored safely elsewhere. An empty worktree is a closed door, not an empty house.
- **It looks twice.** Right before each removal it checks again, because the report you read a minute ago may already be history. Another agent may have moved in since.
- **Detached worktrees stay put.** A commit made in one and then abandoned exists only inside that folder, so removing the folder would erase it.

The complete rules, and the gaps we know about, are in [docs/how-it-works.md](docs/how-it-works.md).

## Setup

It's one bash file with nothing to install, compile, or babysit. You need **git 2.23 or newer** and **bash 3.2 or newer**, which every Mac and Linux machine already has. Your login shell doesn't matter: the script starts with `#!/usr/bin/env bash`, so it behaves the same from zsh, bash, or fish.

### 1. Install

Pick whichever suits you.

**Download it** (simplest):

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/vlad-ko/claude-homeostasis/main/homeostasis -o ~/.local/bin/homeostasis
chmod +x ~/.local/bin/homeostasis
```

**Clone and link it** (a `git pull` keeps it current):

```sh
git clone https://github.com/vlad-ko/claude-homeostasis.git ~/src/claude-homeostasis
mkdir -p ~/.local/bin
ln -s ~/src/claude-homeostasis/homeostasis ~/.local/bin/homeostasis
```

**Commit it to your project** (your team and your agents get it for free): copy `homeostasis` into something like `scripts/`, commit it, and run `scripts/homeostasis`.

### 2. Put `~/.local/bin` on your PATH

Skip this if `echo $PATH` already shows it.

| Shell | Run once |
|---|---|
| **zsh** (the macOS default) | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc` |
| **bash** on Linux | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc` |
| **bash** on macOS | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile && source ~/.bash_profile` |
| **fish** | `fish_add_path ~/.local/bin` |

### 3. Optional extras

- **See open pull requests:** install the [GitHub CLI](https://cli.github.com) and run `gh auth login`. Without it, `homeostasis` can't tell which branches have an open PR, so it errs on the side of caution and removes less.
- **Claude Code users:** nothing to do. Agent worktrees under `.claude/worktrees/` are examined as worktrees and never mistaken for stray files in your main checkout, gitignored or not. Anything else left lying around in there still gets reported.

**Where it runs:** macOS and Linux, both tested in CI. On Windows, use WSL, where it behaves like Linux. Native Windows shells aren't tested.

## Everyday use

```bash
homeostasis           # same as --check
homeostasis --check   # report only. Exit 0 = healthy, 1 = drifted
homeostasis --apply   # do the safe part, then report again
homeostasis --help
```

Run it from anywhere inside a repository, including from inside one of its worktrees.

**The first visit.** Run it and read the report. Each section either says `(ok)` or lists exactly what drifted. REMOVABLE items are what `--apply` would clean; KEEP-DIRTY and INCONCLUSIVE are yours to decide, and the report explains each one. When the list looks right, run `--apply`.

**Make it a habit.** The best checkup is the one nobody has to remember. Add lines like these to your `CLAUDE.md`, and your agents will check the repo's temperature before they call a task done, and use the tool instead of their own judgment when you ask for a cleanup:

> Before you finish a task, run `homeostasis --check` and include the result.
>
> When I ask you to bring my local back to homeostasis, run `homeostasis --check`, show me the report, then run `homeostasis --apply`. Never delete worktrees, branches, files or databases yourself; anything the tool marks KEEP-DIRTY or INCONCLUSIVE is my call.

## Configuration

Most repos need none. If yours does, set environment variables, or put `KEY=value` lines in a `.homeostasis` file at the repo root. The file is read as plain data and never executed. An unknown key earns a warning, and an invalid value stops the run before anything is touched.

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

Commit `.homeostasis` so your whole team shares it. If you'd rather not, list it in `.git/info/exclude`, or the tool will (rightly) report it as a stray file.

`.env` is deliberately not on the regenerable list: it usually holds secrets that nothing can rebuild. If your setup script does recreate it, add it. See [`.homeostasis.example`](.homeostasis.example).

## Tests

```bash
test/run.sh
```

There are 198 checks. They build throwaway repositories and stand in for `gh` and `docker`, so nothing real is ever touched. CI runs them on Linux and macOS.

## License

MIT. Built for a fintech platform, where it keeps a busy fleet of Claude Code agents in balance. Shared because yours drift too.
