#!/usr/bin/env bash
#
# Test harness for `homeostasis`.
#
# Every case is a committed reproduction of a way the tool could lose work or
# lie about the state it read: a FAILED read must never render as "clean", a
# large listing must not SIGPIPE startup, nothing is ever force-removed, the
# worktree the command runs from survives, ignored files are seen, a commitless
# / detached / stale-baseline worktree is never REMOVABLE, and so on.
#
# Isolation guarantees
# --------------------
#   - Every assertion runs inside a throwaway repo under $TMPDIR created by
#     `mktemp -d`, torn down by an EXIT trap.
#   - The script under test is COPIED into each scratch repo and run from
#     there; the repository you run this harness in is never the subject.
#   - `gh` is shadowed by a stub on PATH that exits 0 with no output ("no open
#     PRs, read succeeded"), so no network and no GitHub auth are needed.
#   - `docker` is ALWAYS shadowed by a stub on PATH (the default one answers
#     "only the base `testing` schema exists" and records every statement it is
#     handed), so no real database is ever reached.
#   - `git` is shadowed only in the cases that need a failing or synthetic
#     read; the stub delegates everything else to the real git.
#   - Every HOMEOSTASIS_* variable from the caller's environment is unset.
#
# Portability: bash 3.2+, no GNU-only flags (no `sed -i`, `grep -P`,
# `readlink -f`, or `mktemp --tmpdir`). Runs on macOS and Linux.
#
# Run: test/run.sh        (exit 0 = all passed; 1 = assertion failures;
#                          2 = a fixture could not be built)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="$HERE/../homeostasis"
REAL_GIT="$(command -v git)"

if [ ! -f "$SUBJECT" ]; then
    echo "ERROR: $SUBJECT not found"
    exit 2
fi

unset HOMEOSTASIS_MAIN_BRANCH HOMEOSTASIS_REMOTE HOMEOSTASIS_WORKTREES_DIR \
    HOMEOSTASIS_REGENERABLE HOMEOSTASIS_MYSQL_CONTAINER HOMEOSTASIS_SCHEMA_PREFIX \
    HOMEOSTASIS_GH HOMEOSTASIS_TRUST_NO_PRS
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASS=0
FAIL=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/homeostasis-test.XXXXXX")"
# `mktemp -d` under a symlinked $TMPDIR (macOS /tmp -> /private/tmp) returns
# the symlinked spelling; git reports real paths. Canonicalize once so every
# path this test compares against script output is in git's spelling.
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
# Hermetic git: the host's global config and global excludes file must not
# leak in. A developer's ~/.config/git/ignore (which commonly ignores
# .claude/settings.local.json) silently changed what case 27 saw.
XDG_DIR="$TMPROOT/xdg"
mkdir -p "$XDG_DIR"
export XDG_CONFIG_HOME="$XDG_DIR"
export GIT_CONFIG_GLOBAL=/dev/null
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() {
    case "$TMPROOT" in
        /*/homeostasis-test.*) rm -rf "$TMPROOT" ;;
        *) echo "REFUSING to clean suspicious TMPROOT: $TMPROOT" ;;
    esac
}
trap cleanup EXIT

# --- helpers ----------------------------------------------------------------

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }

# Records a violated assertion WITHOUT exiting: one failing case must not hide
# the state of the others, so $FAIL accumulates and becomes the exit status.
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# fixture_die reports on a duplicate of stderr taken before any fixture runs,
# so a setup step written with its own `2>/dev/null` cannot swallow the reason.
exec 3>&2

# FIXTURE SETUP ABORTS THE WHOLE HARNESS — it never merely counts a failure.
# This file runs WITHOUT `set -e` (many subject invocations exit non-zero on
# purpose), so a setup command that failed silently would leave every later
# assertion judging a state nobody built, and the summary would still read
# "N passed, 0 failed". Exit 2, distinct from an assertion failure.
fixture_die() {
    printf '\n  FIXTURE FAILED: %s\n' "$1" >&3
    exit 2
}

# Runs a fixture-setup command and aborts on non-zero. Three forms, because
# `must` cannot cover the other two:
#   must <cmd>                    a plain setup command.
#   <write> > f || fixture_die    a redirection (the shell opens the target
#                                 before `must` would run).
#   v="$(<read>)" || fixture_die  a read whose value is asserted NEGATIVELY
#                                 (a failed read renders as '' and a negative
#                                 assertion would pass having checked nothing).
must() {
    "$@" || fixture_die "$* (exit $?)"
}

# A fixture git command whose stderr is noise on success and needed on
# failure (cloning an empty bare repo always warns). Stderr is held and
# replayed on fd 3 on a non-zero exit.
git_quiet() {
    local err="" status=0
    err="$(git "$@" 2>&1 1>/dev/null)"
    status=$?
    [ "$status" -eq 0 ] || printf '%s\n' "$err" >&3
    return "$status"
}

assert_dir_exists() {
    if [ -d "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}

assert_dir_missing() {
    if [ ! -d "$1" ]; then pass "$2"; else fail "$2 (still present: $1)"; fi
}

assert_file_missing() {
    if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (exists: $1)"; fi
}

# `grep -F ... >/dev/null`, not `grep -q`: -q exits on the first match and
# SIGPIPEs the printf on a large $1 (case 6 feeds it a 90 KB report).
assert_contains() {
    if printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; then pass "$3"; else fail "$3 (expected to contain: $2)"; fi
}

assert_not_contains() {
    if printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; then fail "$3 (unexpectedly contains: $2)"; else pass "$3"; fi
}

# The report text between "== N." and the next section header.
report_section() {
    printf '%s\n' "$1" | sed -n "/^== $2\\./,/^== [0-9a-z]/p" | sed '$d'
}

assert_exit() {
    if [ "$1" -eq "$2" ]; then pass "$3"; else fail "$3 (exit $1, expected $2)"; fi
}

# Runs the subject: run_hs <layout root> <cwd> <script path> [args...]. Any
# HOMEOSTASIS_* assignment placed before the call reaches the subject.
run_hs() {
    local root="$1" cwd="$2" script="$3"
    shift 3
    (cd "$cwd" && PATH="$root/bin:$PATH" bash "$script" "$@" 2>&1)
}

# Default `docker` stub: any `SHOW DATABASES` answers with the base schema only;
# every invocation is appended to $root/docker.log so a test can assert which
# DROP statements were (or were not) issued. $root/schemas, when present,
# replaces the answer; $root/docker.fail makes every call exit 1.
write_docker_stub() {
    local root="$1"
    cat > "$root/bin/docker" <<STUB || fixture_die "cannot write $root/bin/docker"
#!/bin/sh
printf '%s\n' "\$*" >> "$root/docker.log"
[ ! -e "$root/docker.fail" ] || exit 1
case "\$*" in
    *"SHOW DATABASES"*)
        if [ -f "$root/schemas" ]; then cat "$root/schemas"; else echo testing; fi ;;
esac
exit 0
STUB
    must chmod +x "$root/bin/docker"
}

# `git` stub: delegates to the real git unless the arguments match $2 (a
# `case` pattern against "\$*"), in which case it runs $3 (a shell snippet).
write_git_stub() {
    local root="$1" pattern="$2" action="$3"
    cat > "$root/bin/git" <<STUB || fixture_die "cannot write $root/bin/git"
#!/bin/sh
case "\$*" in
    $pattern) $action ;;
esac
exec "$REAL_GIT" "\$@"
STUB
    must chmod +x "$root/bin/git"
}

# One commit of its own on the branch checked out in worktree $1 — the shape
# of work that was actually produced THERE, and (in a squash-merging
# repository) the shape a branch keeps after its PR lands.
commit_work() {
    local wt="$1" msg="${2:-work}"
    printf '%s\n' "$msg" > "$wt/work.txt" || fixture_die "cannot write $wt/work.txt"
    must git -C "$wt" add work.txt
    # An EMPTY staged diff means this call would commit nothing — a fixture
    # error, not a no-op to shrug at.
    if git -C "$wt" diff --cached --quiet; then
        fixture_die "commit_work $wt '$msg' staged NOTHING — that content is already committed"
    fi
    must git -C "$wt" commit -q -m "$msg"
}

# Builds one scratch layout under $1 (main branch name $2, default main):
#   origin.git      bare remote, main pushed
#   primary/        clone on main == origin/main, carries scripts/homeostasis
#                   and a .gitignore (vendor/, node_modules/, .env, notes.txt,
#                   the worktree parent dir) so ignored-file cases are
#                   expressible
#   wt-self/        worktree on feat/self, clean, NO commit of its own — the
#                   shape of a worktree an agent has just been given
#   wt-sibling/     worktree on feat/sibling, clean, ONE commit of its own —
#                   the shape of finished work (must be removed)
#   feat/landed     a merged branch attached to no worktree (must be deleted)
#   bin/gh          stub: exit 0, no output
#   bin/docker      stub: see write_docker_stub
make_layout() {
    local root="$1" main="${2:-main}"
    must mkdir -p "$root/bin"
    printf '#!/bin/sh\nexit 0\n' > "$root/bin/gh" || fixture_die "cannot write $root/bin/gh"
    must chmod +x "$root/bin/gh"
    write_docker_stub "$root"

    must git init -q --bare "$root/origin.git"
    must git -C "$root/origin.git" symbolic-ref HEAD "refs/heads/$main"
    must git_quiet clone -q "$root/origin.git" "$root/primary"
    git -C "$root/primary" checkout -q -b "$main" 2>/dev/null || must git -C "$root/primary" checkout -q "$main"
    must mkdir -p "$root/primary/scripts"
    must cp "$SUBJECT" "$root/primary/scripts/homeostasis"
    printf 'vendor/\nnode_modules/\n.env\nnotes.txt\n.claude/worktrees/\nalt-worktrees/\n' > "$root/primary/.gitignore" || fixture_die "cannot write $root/primary/.gitignore"
    must git -C "$root/primary" add scripts/homeostasis .gitignore
    must git -C "$root/primary" commit -q -m 'add script'
    must git_quiet -C "$root/primary" push -q -u origin "$main"

    must git -C "$root/primary" worktree add -q "$root/wt-self" -b feat/self
    must git -C "$root/primary" worktree add -q "$root/wt-sibling" -b feat/sibling
    commit_work "$root/wt-sibling" 'sibling work'
    must git -C "$root/primary" branch feat/landed
}

# Strips the layout down to a primary with no worktrees and no extra branches.
clear_layout() {
    local root="$1"
    must git -C "$root/primary" worktree remove "$root/wt-self"
    must git -C "$root/primary" worktree remove "$root/wt-sibling"
    must git -C "$root/primary" branch -q -D feat/self feat/sibling feat/landed
}

# --- 1. run FROM a worktree: it must survive, its sibling must go -------------

echo "1. --apply invoked with the script inside a worktree"
L1="$TMPROOT/from-worktree"
must mkdir -p "$L1"
make_layout "$L1"

# cwd is the primary, the script path is the worktree's copy: the worktree
# holding the script is protected even though cwd is elsewhere.
out="$(run_hs "$L1" "$L1/primary" "$L1/wt-self/scripts/homeostasis" --apply)"
rc=$?

# feat/self is merged (ahead=0) and stays attached to the surviving worktree,
# so the slate is NOT clean: that is a violation, never exit 0.
assert_exit "$rc" 1 "exits 1: the surviving worktree still holds a merged branch"
assert_contains "$out" "VIOLATION: 1 merged branch(es) still attached to a worktree" "the attached merged branch is reported as a VIOLATION"
assert_dir_exists "$L1/wt-self" "the worktree the script runs from survives"
assert_dir_missing "$L1/wt-sibling" "the clean sibling worktree is removed"
assert_contains "$out" "$L1/wt-self  [feat/self]  running from it" "report labels the running worktree IN-USE (running from it)"
assert_not_contains "$out" "cannot change to" "no git -C call failed after the removals"
assert_contains "$out" "removed $L1/wt-sibling  [feat/sibling]" "apply log names the sibling it removed"
listed="$(git -C "$L1/primary" worktree list --porcelain)"
assert_contains "$listed" "worktree $L1/wt-self" "git still lists the running worktree"
assert_not_contains "$listed" "worktree $L1/wt-sibling" "git no longer lists the sibling"
branches="$(git -C "$L1/primary" branch --format='%(refname:short)')"
assert_contains "$branches" "feat/self" "feat/self survives (attached to the running worktree)"
assert_not_contains "$branches" "feat/landed" "the free merged branch is deleted with git branch -d"
assert_contains "$branches" "feat/sibling" "the removed worktree's own commits survive it: git branch -d refuses an unmerged branch and -D is never used"

# --- 1b. cwd inside a worktree, script installed OUTSIDE the repository -------

echo "1b. --apply invoked from inside a worktree with the script installed outside the repo"
L1B="$TMPROOT/from-worktree-cwd"
must mkdir -p "$L1B/installed"
make_layout "$L1B"
must cp "$SUBJECT" "$L1B/installed/homeostasis"

out="$(run_hs "$L1B" "$L1B/wt-self" "$L1B/installed/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "exits 1: the running worktree's merged branch is still a violation"
assert_dir_exists "$L1B/wt-self" "the worktree containing the current directory survives"
assert_contains "$out" "$L1B/wt-self  [feat/self]  running from it" "the cwd worktree is IN-USE (running from it)"
assert_dir_missing "$L1B/wt-sibling" "the sibling is still removed"

# --- 2. run FROM the primary: nothing is excluded, both worktrees go ---------

echo "2. --apply invoked from the primary (the self-exclusion must not over-reach)"
L2="$TMPROOT/from-primary"
must mkdir -p "$L2"
make_layout "$L2"
# wt-self is not the running worktree here, so it must be removable on its own
# merits: give it the finished shape (a commit of its own).
commit_work "$L2/wt-self" 'self work'

out="$(run_hs "$L2" "$L2/primary" "$L2/primary/scripts/homeostasis" --apply)"
rc=$?

assert_exit "$rc" 0 "exits 0 (clean slate after apply)"
assert_dir_missing "$L2/wt-self" "wt-self is removed when the script is not running from it"
assert_dir_missing "$L2/wt-sibling" "wt-sibling is removed"
assert_not_contains "$out" "running from it" "no worktree is labeled running-from when invoked from the primary"
assert_contains "$out" "CLEAN SLATE" "the verdict is CLEAN SLATE"

# --- 3. --check from a worktree never counts itself as REMOVABLE -------------

echo "3. --check invoked from inside a worktree"
L3="$TMPROOT/check-from-worktree"
must mkdir -p "$L3"
make_layout "$L3"
must git -C "$L3/primary" worktree remove "$L3/wt-sibling"
must git -C "$L3/primary" branch -q -D feat/sibling feat/landed

out="$(run_hs "$L3" "$L3/wt-self" "$L3/wt-self/scripts/homeostasis" --check)"
rc=$?

assert_exit "$rc" 1 "exits 1: the running worktree's merged branch is a violation"
assert_contains "$out" "1 worktree(s): 0 REMOVABLE, 0 KEEP-DIRTY, 1 IN-USE, 0 INCONCLUSIVE, 0 PRUNABLE" "the running worktree is counted IN-USE, not REMOVABLE"
assert_contains "$out" "VIOLATION: 1 merged branch(es) still attached to a worktree" "the attached merged branch is counted as a VIOLATION, not merely printed"
assert_not_contains "$out" "CLEAN SLATE" "no CLEAN SLATE verdict while a merged branch exists"

# --- 4. a FAILED `git branch --merged` is INCONCLUSIVE, never "none (ok)" ---

echo "4. git branch --merged fails: merged-branch state is INCONCLUSIVE, nothing deleted"
L4="$TMPROOT/branch-read-fails"
must mkdir -p "$L4"
make_layout "$L4"
must git -C "$L4/primary" worktree remove "$L4/wt-sibling"
write_git_stub "$L4" '*"branch --merged"*' 'echo "fatal: simulated failure" >&2; exit 128'

out="$(run_hs "$L4" "$L4/primary" "$L4/primary/scripts/homeostasis" --apply)"
rc=$?

assert_exit "$rc" 1 "exits 1 (a failed read is never a clean slate)"
assert_contains "$out" "merged-branch read FAILED" "the failed branch read is reported as INCONCLUSIVE"
assert_not_contains "$(report_section "$out" 5)" "none (ok)" "a failed read never renders as 'none (ok)' in the merged-branch section"
branches="$(git -C "$L4/primary" branch --format='%(refname:short)')"
assert_contains "$branches" "feat/landed" "the free merged branch is NOT deleted on a failed read"

# --- 5. a FAILED `git worktree list` is INCONCLUSIVE and blocks --apply ------

echo "5. git worktree list fails after startup: worktree state is INCONCLUSIVE, nothing removed"
L5="$TMPROOT/worktree-read-fails"
must mkdir -p "$L5"
make_layout "$L5"
# The first `worktree list` (startup, resolve_primary) succeeds; every later
# one fails, so the failure lands in the inventory read, not at startup.
write_git_stub "$L5" '*"worktree list"*' "n=\$(cat '$L5/wtlist.count' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$L5/wtlist.count'; if [ \$n -gt 1 ]; then echo 'fatal: simulated failure' >&2; exit 128; fi"

out="$(run_hs "$L5" "$L5/primary" "$L5/primary/scripts/homeostasis" --apply)"
rc=$?

assert_exit "$rc" 1 "exits 1 (a failed read is never a clean slate)"
assert_contains "$out" "worktree listing FAILED" "the failed worktree read is reported as INCONCLUSIVE"
assert_not_contains "$out" "0 worktree(s):" "a failed read never renders as zero worktrees"
assert_dir_exists "$L5/wt-sibling" "no worktree is removed while the listing cannot be read"
assert_not_contains "$out" "removed $L5/wt-sibling" "apply log names nothing removed"

# --- 6. a large `worktree list` must not SIGPIPE startup -------------------

echo "6. 600 synthetic worktrees (90 KB listing): PRIMARY still resolves"
L6="$TMPROOT/large-listing"
must mkdir -p "$L6"
make_layout "$L6"
# The real listing followed by 600 synthetic prunable blocks: far larger than
# a pipe buffer (64 KB), so a reader that closes early (`head -n 1`) SIGPIPEs
# git and, under pipefail+errexit, aborts the script before PRIMARY resolves.
write_git_stub "$L6" '*"worktree list --porcelain"*' "\"$REAL_GIT\" \"\$@\"; i=0; while [ \$i -lt 600 ]; do i=\$((i + 1)); printf 'worktree /nonexistent/%s/synthetic-worktree-%05d\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/synthetic/%s-%05d\nprunable gitdir file points to non-existent location\n\n' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \$i 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' \$i; done; exit 0"

out="$(run_hs "$L6" "$L6/primary" "$L6/primary/scripts/homeostasis" --check)"
rc=$?

assert_exit "$rc" 1 "exits 1 (violations reported), not a startup abort"
assert_contains "$out" "primary worktree $L6/primary" "PRIMARY resolved from the first line of a 90 KB listing"
assert_contains "$out" "600 PRUNABLE" "every synthetic block was read and classified"

# --- 7. a gutted shell is SURFACED, never force-removed ---------------------

echo "7. deletions-only worktree: KEEP-DIRTY and surfaced, never --force removed"
L7="$TMPROOT/gutted-shell"
must mkdir -p "$L7"
make_layout "$L7"
must rm "$L7/wt-sibling/scripts/homeostasis"

out="$(run_hs "$L7" "$L7/primary" "$L7/primary/scripts/homeostasis" --apply)"
rc=$?

assert_exit "$rc" 1 "exits 1 (a surfaced worktree is a violation)"
assert_dir_exists "$L7/wt-sibling" "the gutted shell is left in place"
assert_contains "$out" "$L7/wt-sibling  [feat/sibling]  1 deletion(s) only (gutted shell)" "the gutted shell is surfaced by name as KEEP-DIRTY"
assert_not_contains "$out" "removed $L7/wt-sibling" "apply never removes it"
assert_not_contains "$out" "REMOVABLE-FORCE" "no forced-removal class exists"

# --- 8. an old git is refused at startup -----------------------------------

echo "8. git older than 2.23 (no %(worktreepath)): clear error, exit 2"
L8="$TMPROOT/old-git"
must mkdir -p "$L8"
make_layout "$L8"
write_git_stub "$L8" '--version' 'echo "git version 2.20.1"; exit 0'

out="$(run_hs "$L8" "$L8/primary" "$L8/primary/scripts/homeostasis" --check)"
rc=$?

assert_exit "$rc" 2 "exits 2 on an unsupported git"
assert_contains "$out" "git >= 2.23 required" "the error names the minimum version"
assert_contains "$out" "2.20.1" "the error names the version found"

# --- 9. ignored files are SEEN: regenerable ones do not block, others do ----

echo "9. ignored files: vendor/ + node_modules/ are regenerable; notes.txt and (by default) .env are not"
L9="$TMPROOT/ignored-files"
must mkdir -p "$L9"
make_layout "$L9"
must mkdir -p "$L9/wt-sibling/vendor" "$L9/wt-sibling/node_modules/pkg"
printf 'x\n' > "$L9/wt-sibling/vendor/x" || fixture_die "cannot write vendor/x"
printf 'x\n' > "$L9/wt-sibling/node_modules/pkg/index.js" || fixture_die "cannot write node_modules/pkg/index.js"
printf 'keep me\n' > "$L9/wt-self/notes.txt" || fixture_die "cannot write $L9/wt-self/notes.txt"
# A third worktree that is finished work but holds a gitignored .env.
must git -C "$L9/primary" worktree add -q "$L9/wt-env" -b feat/env
commit_work "$L9/wt-env" 'env work'
printf 'SECRET=1\n' > "$L9/wt-env/.env" || fixture_die "cannot write $L9/wt-env/.env"

out="$(run_hs "$L9" "$L9/primary" "$L9/primary/scripts/homeostasis" --apply)"
rc=$?

assert_exit "$rc" 1 "exits 1 (the surfaced worktrees are violations)"
assert_dir_missing "$L9/wt-sibling" "a worktree holding only regenerable ignored paths is removed"
assert_dir_exists "$L9/wt-self" "a worktree holding a non-regenerable ignored file is kept"
assert_contains "$out" "$L9/wt-self  [feat/self]  ignored non-regenerable path: notes.txt" "the blocking ignored path is surfaced by name"
assert_dir_exists "$L9/wt-env" ".env is NOT regenerable by default: the worktree holding it is kept"
assert_contains "$out" "$L9/wt-env  [feat/env]  ignored non-regenerable path: .env" "the .env is surfaced by name"

# Opting .env into the allowlist makes the same worktree removable.
out="$(HOMEOSTASIS_REGENERABLE="vendor node_modules .env" run_hs "$L9" "$L9/primary" "$L9/primary/scripts/homeostasis" --apply)"
assert_dir_missing "$L9/wt-env" "with .env added to HOMEOSTASIS_REGENERABLE the worktree is removable"

# --- 10. debris directories under .claude/worktrees ------------------------

echo "10. debris: a directory git no longer registers is listed; removed only when regenerable"
L10="$TMPROOT/debris"
must mkdir -p "$L10"
make_layout "$L10"
WTD="$L10/primary/.claude/worktrees"
must mkdir -p "$WTD"
# (a) registered, then its .git file lost mid-removal: holds only vendor/ +
#     node_modules/ + a scratch .json -> removable debris
must git -C "$L10/primary" worktree add -q "$WTD/wt-debris" -b feat/debris
must mkdir -p "$WTD/wt-debris/vendor/pkg" "$WTD/wt-debris/node_modules/x"
printf 'x\n' > "$WTD/wt-debris/vendor/pkg/x.php" || fixture_die "cannot write vendor/pkg/x.php"
printf 'l\n' > "$WTD/wt-debris/node_modules/x/index.js" || fixture_die "cannot write node_modules/x/index.js"
printf '{}\n' > "$WTD/wt-debris/scratch.json" || fixture_die "cannot write scratch.json"
must rm -rf "$WTD/wt-debris/.git" "$WTD/wt-debris/scripts" "$WTD/wt-debris/.gitignore"
# (b) unregistered, holds source-shaped content -> surfaced
must mkdir -p "$WTD/wt-debris-src/vendor" "$WTD/wt-debris-src/src"
printf 'x\n' > "$WTD/wt-debris-src/vendor/x" || fixture_die "cannot write vendor/x"
printf 'int main;\n' > "$WTD/wt-debris-src/src/main.c" || fixture_die "cannot write src/main.c"
# (c) unregistered but still carries a .git file -> surfaced
must mkdir -p "$WTD/wt-debris-git/vendor"
printf 'gitdir: /nowhere\n' > "$WTD/wt-debris-git/.git" || fixture_die "cannot write .git"

out="$(run_hs "$L10" "$L10/primary" "$L10/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1 on debris"
assert_contains "$out" "3 DEBRIS director" "--check counts every unregistered directory as DEBRIS"
assert_contains "$out" "$WTD/wt-debris  " "--check names the removable debris dir"
assert_contains "$out" "$WTD/wt-debris-src  " "--check names the source-shaped debris dir"

out="$(run_hs "$L10" "$L10/primary" "$L10/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "--apply exits 1 (two debris dirs remain surfaced)"
assert_dir_missing "$WTD/wt-debris" "regenerable-only debris (no .git) is removed"
assert_dir_exists "$WTD/wt-debris-src" "source-shaped debris is surfaced, never removed"
assert_contains "$out" "$WTD/wt-debris-src  src/main.c" "the offending path is named"
assert_dir_exists "$WTD/wt-debris-git" "debris still carrying a .git file is surfaced, never removed"
assert_contains "$out" "$WTD/wt-debris-git  .git" "the .git file is named as the reason"
assert_contains "$out" "removed debris $WTD/wt-debris" "apply log names the debris dir it removed"
listed="$(git -C "$L10/primary" worktree list --porcelain)" || fixture_die "cannot list the worktrees of $L10/primary"
assert_not_contains "$listed" "wt-debris" "git registers none of the debris dirs after prune"

# An empty HOMEOSTASIS_WORKTREES_DIR disables the debris check entirely.
out="$(HOMEOSTASIS_WORKTREES_DIR='' run_hs "$L10" "$L10/primary" "$L10/primary/scripts/homeostasis" --check)"
assert_contains "$(report_section "$out" 6)" "skipped (HOMEOSTASIS_WORKTREES_DIR is empty)" "an empty HOMEOSTASIS_WORKTREES_DIR skips the debris check"
assert_not_contains "$out" "DEBRIS director" "a skipped debris check reports no violation"

# --- 11. orphan test schemas -----------------------------------------------

echo "11. orphan test schemas: listed as violations, dropped only when no worktree maps to them"
L11="$TMPROOT/orphan-schemas"
must mkdir -p "$L11"
make_layout "$L11"
# wt-self is locked (IN-USE) and agent-abc123 holds source-shaped content, so
# both SURVIVE --apply and their schemas must survive with them; wt-sibling is
# removed by --apply, so its schema is a genuine orphan by the time DROP runs.
must git -C "$L11/primary" worktree lock "$L11/wt-self"
must mkdir -p "$L11/primary/.claude/worktrees/agent-abc123/src"
printf 'x\n' > "$L11/primary/.claude/worktrees/agent-abc123/src/main.c" || fixture_die "cannot write agent-abc123/src/main.c"
printf 'testing\ntesting_wt_self\ntesting_wt_sibling\ntesting_agent_abc123\ntesting_agent_gone\ntesting_orphan_x\ntesting_primary\n' > "$L11/schemas" || fixture_die "cannot write $L11/schemas"

out="$(HOMEOSTASIS_MYSQL_CONTAINER=testdb run_hs "$L11" "$L11/primary" "$L11/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1 on orphan schemas"
assert_contains "$out" "2 orphan test schema(s)" "--check counts the two schemas with no worktree"
assert_contains "$out" "testing_agent_gone" "--check names an orphan"
assert_not_contains "$out" "DROP DATABASE" "--check never drops"

out="$(HOMEOSTASIS_MYSQL_CONTAINER=testdb run_hs "$L11" "$L11/primary" "$L11/primary/scripts/homeostasis" --apply)"
rc=$?
log="$(cat "$L11/docker.log")"
assert_contains "$log" "DROP DATABASE \`testing_agent_gone\`" "--apply drops an orphan whose name maps to no directory"
assert_contains "$log" "DROP DATABASE \`testing_orphan_x\`" "--apply drops the second orphan"
assert_not_contains "$log" "DROP DATABASE \`testing_wt_self\`" "a schema mapping to a registered worktree is never dropped"
assert_not_contains "$log" "DROP DATABASE \`testing_agent_abc123\`" "a schema mapping to a directory under .claude/worktrees is never dropped"
assert_not_contains "$log" "DROP DATABASE \`testing_primary\`" "the primary's own derived schema is never dropped"
assert_not_contains "$log" "DROP DATABASE \`testing\`" "the base testing schema is never dropped"
assert_contains "$log" "DROP DATABASE \`testing_wt_sibling\`" "the schema of a worktree --apply just removed is dropped in the same run"

# --- 12. an unreachable MySQL is INCONCLUSIVE, never "0 orphans" ------------

echo "12. docker/mysql unreachable: orphan-schema state is INCONCLUSIVE"
L12="$TMPROOT/mysql-unreachable"
must mkdir -p "$L12"
make_layout "$L12"
clear_layout "$L12"
: > "$L12/docker.fail" || fixture_die "cannot create $L12/docker.fail"

out="$(HOMEOSTASIS_MYSQL_CONTAINER=testdb run_hs "$L12" "$L12/primary" "$L12/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "exits 1 (a failed read is never a clean slate)"
assert_contains "$out" "test-schema read FAILED" "the failed docker read is reported as INCONCLUSIVE"
assert_not_contains "$out" "0 orphan" "a failed read never renders as zero orphans"
assert_not_contains "$out" "CLEAN SLATE" "no CLEAN SLATE verdict on a failed read"

# --- 13. a LIVE schema in a >64 KB live list is never an orphan ------------
#
# `printf '%s\n' "$live" | grep -qxF -- "$schema"` under pipefail: grep -q
# exits on the first match and closes the pipe; once $live is larger than a
# pipe buffer printf takes SIGPIPE, the pipeline reads non-zero on a REAL
# match, and a live schema is classified ORPHAN — and DROPPED by --apply.
# 1100 directories with 56-char names make $live ~72 KB.

echo "13. 1100 worktree directories (72 KB live list): a registered worktree's schema is never an orphan"
L13="$TMPROOT/large-live-list"
must mkdir -p "$L13"
make_layout "$L13"
WTD="$L13/primary/.claude/worktrees"
must mkdir -p "$WTD"
i=0
while [ $i -lt 1100 ]; do
    i=$((i + 1))
    must mkdir "$WTD/$(printf 'dddddddddddddddddddddddddddddddddddddddddddddddddddd%04d' $i)"
done
printf 'testing\ntesting_wt_self\ntesting_orphan_x\n' > "$L13/schemas" || fixture_die "cannot write $L13/schemas"

out="$(HOMEOSTASIS_MYSQL_CONTAINER=testdb run_hs "$L13" "$L13/primary" "$L13/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1 (the debris dirs and the one real orphan are violations)"
assert_contains "$out" "1 orphan test schema(s)" "--check counts ONLY the schema with no worktree"
assert_contains "$(report_section "$out" 7)" "testing_orphan_x" "the genuine orphan is still reported"
assert_not_contains "$(report_section "$out" 7)" "testing_wt_self" "the registered worktree's schema (line 1 of a 72 KB live list) is not reported as an orphan"

# --- 14. a REGISTERED dir in a >64 KB registered list is never debris -------

echo "14. 260 registered worktrees (72 KB registered list): a registered directory is never debris"
L14="$TMPROOT/large-registered-list"
must mkdir -p "$L14"
make_layout "$L14"
commit_work "$L14/wt-self" 'self work'
WTD="$L14/primary/.claude/worktrees"
must mkdir -p "$WTD" "$L14/syn"
must git -C "$L14/primary" worktree add -q "$WTD/wt-reg" -b feat/reg
must git -C "$L14/primary" worktree lock "$WTD/wt-reg"
SYN_NAME="$(printf 's%.0s' $(seq 1 240))"
i=0
while [ $i -lt 260 ]; do
    i=$((i + 1))
    must mkdir "$L14/syn/$(printf '%s%04d' "$SYN_NAME" $i)"
done
write_git_stub "$L14" '*"worktree list --porcelain"*' "\"$REAL_GIT\" \"\$@\"; for d in '$L14'/syn/*; do printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/synthetic/%s\n\n' \"\$d\" \"\${d##*/}\"; done; exit 0"

out="$(run_hs "$L14" "$L14/primary" "$L14/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1 (the synthetic worktrees are INCONCLUSIVE violations)"
assert_contains "$out" "260 INCONCLUSIVE" "every synthetic block was read as a registered worktree"
assert_not_contains "$(report_section "$out" 6)" "wt-reg" "the registered directory (line 3 of a 72 KB registered list) is not reported as debris"
assert_contains "$(report_section "$out" 6)" "none (ok)" "no debris exists"

# --- 15. an over-length name reports the REASON, never a partial live list --

echo "15. a worktree-dir name too long for a schema: the violation is the reason, not a schema list"
L15="$TMPROOT/overlong-name"
must mkdir -p "$L15"
make_layout "$L15"
WTD="$L15/primary/.claude/worktrees"
LONG="agent-$(printf 'l%.0s' $(seq 1 60))"
must mkdir -p "$WTD/$LONG"
printf 'testing\ntesting_wt_self\n' > "$L15/schemas" || fixture_die "cannot write $L15/schemas"

out="$(HOMEOSTASIS_MYSQL_CONTAINER=testdb run_hs "$L15" "$L15/primary" "$L15/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "exits 1 (an unknown live set is never a clean slate)"
assert_contains "$out" "VIOLATION: directory name '$LONG' is too long" "the violation line IS the reason"
assert_not_contains "$(report_section "$out" 7)" "testing_wt_self" "no schema name leaks into section 7 as part of the 'reason'"

# --- 16. a worktree with no commit of its own is NEVER removable ------------
#
# A clean tree plus a branch contained in main is true of a worktree created
# seconds ago (an agent may be about to build in it) AND of one whose work has
# landed. Opposite states, one key. The matrix below separates them, and the
# last assertions prove the guard is not a no-op: a squash-merged branch keeps
# its own commits and stays removable.

echo "16. a commitless worktree is INCONCLUSIVE (never REMOVABLE); a committed one still is"
L16="$TMPROOT/commitless-worktree"
must mkdir -p "$L16"
make_layout "$L16"
must git -C "$L16/primary" worktree remove "$L16/wt-self"
must git -C "$L16/primary" worktree remove "$L16/wt-sibling"
# (a) finished and LANDED via squash merge — must stay REMOVABLE.
must git -C "$L16/primary" worktree add -q "$L16/wt-done" -b fix/done
commit_work "$L16/wt-done" 'done work'
must git_quiet -C "$L16/primary" merge -q --squash fix/done
must git -C "$L16/primary" commit -q -m 'land fix/done (squash)'
# (b) brand new: created from main, nothing committed yet, tree clean.
must git -C "$L16/primary" worktree add -q "$L16/wt-new" -b fix/new
# (c) commits of its own, no PR, not in main — REMOVABLE.
must git -C "$L16/primary" worktree add -q "$L16/wt-ahead" -b fix/ahead
commit_work "$L16/wt-ahead" 'ahead work'
# (d) an OPEN PR — IN-USE.
must git -C "$L16/primary" worktree add -q "$L16/wt-pr" -b fix/pr
commit_work "$L16/wt-pr" 'pr work'
printf '#!/bin/sh\nprintf "fix/pr\\n"\n' > "$L16/bin/gh" || fixture_die "cannot write $L16/bin/gh"
must chmod +x "$L16/bin/gh"
# (e) brand new AND already edited: KEEP-DIRTY, surfaced with its edits.
must git -C "$L16/primary" worktree add -q "$L16/wt-typing" -b fix/typing
printf 'draft\n' > "$L16/wt-typing/Draft.txt" || fixture_die "cannot write $L16/wt-typing/Draft.txt"

out="$(run_hs "$L16" "$L16/primary" "$L16/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1 (an unprovable worktree is never a clean slate)"
assert_contains "$out" "5 worktree(s): 2 REMOVABLE, 1 KEEP-DIRTY, 1 IN-USE, 1 INCONCLUSIVE, 0 PRUNABLE" \
    "the commitless worktree is counted INCONCLUSIVE, not REMOVABLE"
assert_contains "$out" "$L16/wt-new  [fix/new]  no commit of its own" "the commitless worktree is named with the reason"
assert_not_contains "$(report_section "$out" 4)" "$L16/wt-new  [fix/new]  clean" "the commitless worktree is never reported clean/removable"
assert_contains "$out" "$L16/wt-typing  [fix/typing]  1 status entries" "a commitless worktree with an edit is KEEP-DIRTY, surfaced with its edits"
assert_contains "$out" "$L16/wt-pr  [fix/pr]  open PR on fix/pr" "an open PR is still IN-USE"

out="$(run_hs "$L16" "$L16/primary" "$L16/primary/scripts/homeostasis" --apply)"
rc=$?
assert_dir_exists "$L16/wt-new" "--apply never removes a worktree with no commit of its own"
assert_not_contains "$out" "removed $L16/wt-new" "apply log names no removal of the commitless worktree"
assert_dir_exists "$L16/wt-typing" "--apply never removes a commitless worktree that has been edited"
assert_dir_exists "$L16/wt-pr" "--apply never removes a worktree with an open PR"
assert_dir_missing "$L16/wt-done" "--apply still removes the worktree whose work landed (not a no-op)"
assert_dir_missing "$L16/wt-ahead" "--apply still removes a clean worktree whose commits main does not have"
assert_contains "$out" "removed $L16/wt-done  [fix/done]" "apply log names the finished worktree it removed"
assert_exit "$rc" 1 "--apply exits 1 (the commitless worktrees remain, surfaced)"

# --- 17. a FAILED commit-count read is INCONCLUSIVE, never REMOVABLE --------

echo "17. git rev-list --count fails: the worktree is INCONCLUSIVE, nothing removed"
L17="$TMPROOT/commit-count-read-fails"
must mkdir -p "$L17"
make_layout "$L17"
must git -C "$L17/primary" worktree remove "$L17/wt-self"
write_git_stub "$L17" '*"rev-list --count refs/heads/main..HEAD"*' 'echo "fatal: simulated failure" >&2; exit 128'

out="$(run_hs "$L17" "$L17/primary" "$L17/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "exits 1 (a failed read is never a clean slate)"
assert_contains "$out" "commit count unreadable" "the failed commit-count read is reported as INCONCLUSIVE"
assert_contains "$out" "git rev-list --count main..HEAD exited 128: fatal: simulated failure" \
    "the reason carries the git exit status and its stderr, not just the word unreadable"
assert_not_contains "$out" "1 REMOVABLE" "a failed read never renders as a removable worktree"
assert_dir_exists "$L17/wt-sibling" "nothing is removed while the commit count cannot be read"

# --- 18. a DETACHED worktree is never REMOVABLE, however many commits it has --

echo "18. a clean detached worktree with its own commits is INCONCLUSIVE, never removed"
L18="$TMPROOT/detached-worktree"
must mkdir -p "$L18"
make_layout "$L18"
clear_layout "$L18"
must git -C "$L18/primary" worktree add -q --detach "$L18/wt-detached"
commit_work "$L18/wt-detached" 'detached work'
DETACHED_SHA="$(git -C "$L18/wt-detached" rev-parse HEAD)"
branch_tips="$(git -C "$L18/primary" branch --format='%(objectname)')" || fixture_die "cannot list the branch tips of $L18/primary"
assert_not_contains "$branch_tips" "$DETACHED_SHA" \
    "fixture: no branch ref points at the detached commit (removal would strand it)"

out="$(run_hs "$L18" "$L18/primary" "$L18/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "--apply exits 1 (a detached worktree is never a clean slate)"
assert_contains "$out" "1 worktree(s): 0 REMOVABLE, 0 KEEP-DIRTY, 0 IN-USE, 1 INCONCLUSIVE, 0 PRUNABLE" \
    "the detached worktree is counted INCONCLUSIVE, not REMOVABLE"
assert_contains "$out" "$L18/wt-detached  [(detached)]  HEAD is not a branch ref" \
    "the detached worktree is named with the reason no count could override"
assert_dir_exists "$L18/wt-detached" "--apply never removes a DETACHED worktree, whose commits no ref would survive"
assert_not_contains "$out" "removed $L18/wt-detached" "apply log names no removal of the detached worktree"

# --- 19. a stale local main makes every commit count a phantom -------------
#
# The count is measured against the LOCAL main ref, and the script only
# FETCHES the remote — it never advances local main. A worktree created from
# the freshly fetched tip while the primary sat behind carries upstream commits
# it merely INHERITED. The second half proves the commits were phantom: once
# main is fast-forwarded, the same untouched worktree reads 0.

echo "19. local main behind origin/main: inherited commits never count as the worktree's own"
L19="$TMPROOT/stale-main-baseline"
must mkdir -p "$L19"
make_layout "$L19"
must git -C "$L19/primary" worktree remove "$L19/wt-self"
must git -C "$L19/primary" checkout -q -b tmp/upstream
printf 'upstream\n' > "$L19/primary/upstream.txt" || fixture_die "cannot write upstream.txt"
must git -C "$L19/primary" add upstream.txt
must git -C "$L19/primary" commit -q -m 'upstream work'
must git_quiet -C "$L19/primary" push -q origin tmp/upstream:main
must git -C "$L19/primary" checkout -q main
must git -C "$L19/primary" branch -q -D tmp/upstream
must git -C "$L19/primary" worktree add -q "$L19/wt-fresh" -b fix/fresh refs/remotes/origin/main
assert_contains "$(git -C "$L19/primary" rev-list --count 'refs/heads/main..refs/remotes/origin/main')" "1" \
    "fixture: local main is 1 commit behind origin/main"
assert_contains "$(git -C "$L19/wt-fresh" rev-list --count 'refs/heads/main..HEAD')" "1" \
    "fixture: the untouched worktree reads 1 phantom commit against the stale local main"

out="$(run_hs "$L19" "$L19/primary" "$L19/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "--apply exits 1 (a stale baseline is never a clean slate)"
assert_contains "$out" "2 worktree(s): 0 REMOVABLE, 0 KEEP-DIRTY, 0 IN-USE, 2 INCONCLUSIVE, 0 PRUNABLE" \
    "while the baseline is unproven NO worktree is REMOVABLE, not even one with real commits"
assert_contains "$out" "$L19/wt-fresh  [fix/fresh]  the commit count cannot be trusted: local main is 1 commit(s) BEHIND origin/main" \
    "the worktree line itself names the stale baseline as the reason no count was believed"
assert_dir_exists "$L19/wt-fresh" "--apply never removes a worktree whose only commits came from a newer origin/main"
assert_dir_exists "$L19/wt-sibling" "--apply removes nothing at all while local main is behind origin/main"

must git -C "$L19/primary" merge -q --ff-only refs/remotes/origin/main
out="$(run_hs "$L19" "$L19/primary" "$L19/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "--apply still exits 1 (the commitless worktree remains, surfaced)"
assert_contains "$out" "$L19/wt-fresh  [fix/fresh]  no commit of its own" \
    "once main is fresh the same untouched worktree reads 0 commits of its own — the count was a phantom"
assert_dir_exists "$L19/wt-fresh" "--apply preserves the commitless worktree after the fast-forward too"
assert_dir_missing "$L19/wt-sibling" "--apply removes the worktree with real commits once the baseline is proven (not a no-op)"

# --- 20. a detached worktree at ZERO own commits still holds unnamed work ----
#
# `rev-list main..HEAD` answers "is HEAD's history in main", NOT "did this
# worktree ever produce a commit". The layout below reads ZERO with a clean
# tree while holding a commit named by NOTHING but its own logs/HEAD — which
# `git worktree remove` deletes with the directory. The identical abandonment
# on a branch survives, because that reflog lives in the common dir. Both the
# detached refusal and the commitless refusal cover this layout; what the case
# pins is the FACT that justifies never narrowing the detached refusal.

echo "20. a detached worktree reading ZERO own commits still holds work only its own reflog names"
L20="$TMPROOT/detached-zero-count"
must mkdir -p "$L20"
make_layout "$L20"
clear_layout "$L20"
must git -C "$L20/primary" worktree add -q --detach "$L20/wt-abandoned"
commit_work "$L20/wt-abandoned" 'abandoned work'
ABANDONED_SHA="$(git -C "$L20/wt-abandoned" rev-parse HEAD)"
must git -C "$L20/wt-abandoned" reset -q --hard refs/heads/main
WT_GITDIR="$(git -C "$L20/wt-abandoned" rev-parse --absolute-git-dir)"

assert_contains "$(git -C "$L20/wt-abandoned" rev-list --count 'refs/heads/main..HEAD')" "0" \
    "fixture: the abandoned worktree reads ZERO own commits against main"
abandoned_status="$(git -C "$L20/wt-abandoned" status --porcelain --ignored)" \
    || fixture_die "cannot read the status of $L20/wt-abandoned"
assert_contains "[$abandoned_status]" "[]" \
    "fixture: and its tree is clean, so every other test would pass it"
assert_contains "$(cat "$WT_GITDIR/logs/HEAD")" "$ABANDONED_SHA" \
    "fixture: the abandoned commit is named by this worktree's own logs/HEAD"
common_reflog="$(cat "$L20/primary/.git/logs/HEAD")" || fixture_die "cannot read $L20/primary/.git/logs/HEAD"
assert_not_contains "$common_reflog" "$ABANDONED_SHA" \
    "fixture: no common-dir reflog names it — the removal would destroy its last record"

out="$(run_hs "$L20" "$L20/primary" "$L20/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "--apply exits 1 (a detached worktree is never a clean slate)"
assert_dir_exists "$L20/wt-abandoned" "--apply never removes a DETACHED worktree even when its own-commit count is zero"
assert_contains "$(cat "$WT_GITDIR/logs/HEAD" 2>/dev/null)" "$ABANDONED_SHA" \
    "the last record of the abandoned commit survives --apply"
assert_contains "$out" "Remove it by hand when you are done with it: git worktree remove $L20/wt-abandoned" \
    "the violation names the remedy, so a correct standing state is actionable rather than noise"

# --- 21. pr<N> scratch branches -----------------------------------------------

echo "21. pr<N> scratch branches: gh MERGED at this exact tip force-deletes (-D); OPEN/gh-failure/diverged-tip untouched"
L21="$TMPROOT/pr-scratch-branches"
must mkdir -p "$L21"
make_layout "$L21"
# pr11, pr-14-review and pr99 each get ONE commit of their own, never merged
# into main — the squash-merge shape: `git branch --merged main` says "not
# merged" for every one of them forever. pr11's tip IS the PR's headRefOid —
# removable. pr15 gets a SECOND commit after the one gh reports as headRefOid:
# state MERGED alone must never license deleting it.
must git -C "$L21/primary" checkout -q -b pr11
commit_work "$L21/primary" 'pr11 content'
PR11_SHA="$(git -C "$L21/primary" rev-parse pr11)" || fixture_die "cannot read pr11 tip"

must git -C "$L21/primary" checkout -q -b pr-14-review main
commit_work "$L21/primary" 'pr14 content'

must git -C "$L21/primary" checkout -q -b pr99 main
commit_work "$L21/primary" 'pr99 content'

must git -C "$L21/primary" checkout -q -b pr15 main
commit_work "$L21/primary" 'pr15 merged content'
PR15_MERGED_SHA="$(git -C "$L21/primary" rev-parse pr15)" || fixture_die "cannot read pr15 merged-head tip"
commit_work "$L21/primary" 'pr15 extra local commit made after the PR merged'
PR15_TIP_SHA="$(git -C "$L21/primary" rev-parse pr15)" || fixture_die "cannot read pr15 current tip"

must git -C "$L21/primary" checkout -q main
cat > "$L21/bin/gh" <<STUB || fixture_die "cannot write $L21/bin/gh"
#!/bin/sh
case "\$*" in
    'pr view 11 --json state,headRefOid -q .state + "\t" + .headRefOid') printf 'MERGED\t%s\n' "$PR11_SHA"; exit 0 ;;
    'pr view 14 --json state,headRefOid -q .state + "\t" + .headRefOid') echo OPEN; exit 0 ;;
    'pr view 99 --json state,headRefOid -q .state + "\t" + .headRefOid') echo "gh: could not resolve to a PullRequest" >&2; exit 1 ;;
    'pr view 15 --json state,headRefOid -q .state + "\t" + .headRefOid') printf 'MERGED\t%s\n' "$PR15_MERGED_SHA"; exit 0 ;;
esac
exit 0
STUB
must chmod +x "$L21/bin/gh"

out="$(run_hs "$L21" "$L21/primary" "$L21/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "--check exits 1: a MERGED-at-this-tip scratch branch, a diverged-tip one and a failed gh read are all violations"
assert_contains "$(report_section "$out" 5b)" "pr11  (PR 11 MERGED)" \
    "the squash-merged scratch branch whose tip matches the merged head is identified"
assert_contains "$out" "VIOLATION: 1 pr<N> scratch branch(es) whose PR gh confirms MERGED at this exact tip" \
    "the gh-confirmed-MERGED-at-this-tip branch is reported as removable"
assert_contains "$out" "VIOLATION: 1 pr<N> scratch branch(es) whose gh read FAILED" \
    "a failed gh read is INCONCLUSIVE, never silently fine to delete"
assert_contains "$out" "pr99  (PR 99: INCONCLUSIVE" \
    "the failed-read branch names its own PR number alongside the reason"
assert_contains "$out" "VIOLATION: 1 pr<N> scratch branch(es) whose PR gh confirms MERGED but whose local tip is NOT the merged head" \
    "a MERGED branch whose local tip has diverged is its OWN violation bucket"
assert_contains "$out" "pr15  (PR 15: local tip $PR15_TIP_SHA != PR 15 merged head $PR15_MERGED_SHA)" \
    "the diverged branch names its own tip and the merged head it no longer equals"
assert_not_contains "$out" "pr-14-review" \
    "an OPEN PR's scratch branch is never reported at all"

out="$(run_hs "$L21" "$L21/primary" "$L21/primary/scripts/homeostasis" --apply)"
branches="$(git -C "$L21/primary" branch --format='%(refname:short)')" \
    || fixture_die "cannot list branches of $L21/primary after --apply"
assert_not_contains "$branches" "pr11" \
    "the branch whose tip IS the PR's merged head is force-deleted"
assert_contains "$branches" "pr15" \
    "the branch whose tip has DIVERGED survives --apply untouched"
assert_contains "$branches" "pr-14-review" \
    "the OPEN PR's scratch branch survives --apply untouched"
assert_contains "$branches" "pr99" \
    "the branch whose gh read failed survives --apply untouched"
assert_contains "$out" "deleted pr11 (PR 11 MERGED)" \
    "the apply log names the branch and its PR number"
assert_not_contains "$out" "deleted pr15" \
    "the diverged-tip branch is never force-deleted"

# --- 22. config file: parsed, never sourced ----------------------------------

echo "22. .homeostasis config: allowlisted keys applied, unknown keys warned, nothing executed"
L22="$TMPROOT/config-file"
must mkdir -p "$L22"
make_layout "$L22"
clear_layout "$L22"
must mkdir -p "$L22/primary/alt-worktrees/stray/src"
printf 'x\n' > "$L22/primary/alt-worktrees/stray/src/a.c" || fixture_die "cannot write alt-worktrees/stray/src/a.c"
{
    printf '# comment line\n\n'
    printf 'HOMEOSTASIS_WORKTREES_DIR="alt-worktrees"\n'
    # shellcheck disable=SC2016  # the literal $(...) is the attack being tested
    printf 'EVIL_KEY=$(touch %s/pwned-unknown)\n' "$L22"
    # shellcheck disable=SC2016  # the literal $(...) is the attack being tested
    printf '$(touch %s/pwned-line)\n' "$L22"
    printf 'HOMEOSTASIS_GH=auto\n'
} > "$L22/primary/.homeostasis" || fixture_die "cannot write .homeostasis"
must git -C "$L22/primary" add .homeostasis
must git -C "$L22/primary" commit -q -m 'config'
must git_quiet -C "$L22/primary" push -q origin main

out="$(run_hs "$L22" "$L22/primary" "$L22/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "exits 1 (the stray directory under the configured worktree dir is debris)"
assert_contains "$out" "unknown key 'EVIL_KEY' ignored" "an unknown key is ignored with a warning"
assert_contains "$out" "not a KEY=value line, ignored" "a malformed line is ignored with a warning"
assert_file_missing "$L22/pwned-unknown" "an unknown key's value is never executed"
assert_file_missing "$L22/pwned-line" "a malformed line is never executed"
assert_contains "$(report_section "$out" 6)" "$L22/primary/alt-worktrees/stray  src/a.c" "HOMEOSTASIS_WORKTREES_DIR from the file is applied (quotes stripped)"

# The environment wins over the file.
out="$(HOMEOSTASIS_WORKTREES_DIR='' run_hs "$L22" "$L22/primary" "$L22/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 0 "an environment value overrides the file (debris check disabled -> clean)"

# A known key with a value that tries command substitution is refused, and
# still never executed.
# shellcheck disable=SC2016  # the literal $(...) and backticks are the attack being tested
printf 'HOMEOSTASIS_REGENERABLE=vendor $(touch %s/pwned-value) `touch %s/pwned-tick`\n' "$L22" "$L22" > "$L22/primary/.homeostasis" \
    || fixture_die "cannot rewrite .homeostasis"
out="$(run_hs "$L22" "$L22/primary" "$L22/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 2 "an invalid value for a known key is fatal (exit 2), never a silent fallback"
assert_contains "$out" "invalid HOMEOSTASIS_REGENERABLE entry" "the error names the key"
assert_file_missing "$L22/pwned-value" "a \$(...) value is never executed"
assert_file_missing "$L22/pwned-tick" "a backtick value is never executed"

printf 'HOMEOSTASIS_WORKTREES_DIR=../outside\n' > "$L22/primary/.homeostasis" || fixture_die "cannot rewrite .homeostasis"
out="$(run_hs "$L22" "$L22/primary" "$L22/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 2 "a worktree dir escaping the repository is refused"
assert_contains "$out" "invalid HOMEOSTASIS_WORKTREES_DIR" "the error names the key"

# --- 23. main branch auto-detected from <remote>/HEAD ------------------------

echo "23. main branch auto-detect: a repository whose default branch is 'trunk'"
L23="$TMPROOT/autodetect-main"
must mkdir -p "$L23"
make_layout "$L23" trunk
clear_layout "$L23"
must git -C "$L23/primary" remote set-head origin trunk

out="$(run_hs "$L23" "$L23/primary" "$L23/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 0 "a clean repository on 'trunk' is a clean slate"
assert_contains "$out" "main branch trunk (from origin/HEAD)" "the main branch is read from origin/HEAD"
assert_contains "$out" "branch: trunk (ok)" "the primary is checked against the detected branch"

out="$(HOMEOSTASIS_MAIN_BRANCH=main run_hs "$L23" "$L23/primary" "$L23/primary/scripts/homeostasis" --check)"
rc=$?
assert_exit "$rc" 1 "an explicit HOMEOSTASIS_MAIN_BRANCH overrides the detection"
assert_contains "$out" "primary is on 'trunk' (must be on main)" "the configured branch is the one enforced"

# --- 24. schema check is skipped unless configured ---------------------------

echo "24. orphan-schema check: skipped and never a violation unless HOMEOSTASIS_MYSQL_CONTAINER is set"
L24="$TMPROOT/schema-unconfigured"
must mkdir -p "$L24"
make_layout "$L24"
clear_layout "$L24"
: > "$L24/docker.fail" || fixture_die "cannot create $L24/docker.fail"

out="$(run_hs "$L24" "$L24/primary" "$L24/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 0 "a clean repository with the schema check unconfigured is a clean slate"
assert_contains "$(report_section "$out" 7)" "skipped (not configured" "section 7 says it was skipped"
assert_file_missing "$L24/docker.log" "docker is never invoked when the check is not configured"

# --- 25. gh off, with and without HOMEOSTASIS_TRUST_NO_PRS -------------------

echo "25. HOMEOSTASIS_GH=off: INCONCLUSIVE by default; HOMEOSTASIS_TRUST_NO_PRS=1 opts in, loudly"
L25="$TMPROOT/gh-off"
must mkdir -p "$L25"
make_layout "$L25"
must git -C "$L25/primary" worktree remove "$L25/wt-self"
must git -C "$L25/primary" branch -q -D feat/self feat/landed
# A gh stub that would CRASH the run if called: with gh off it must not be.
printf '#!/bin/sh\necho "gh must not be called" >&2\nexit 99\n' > "$L25/bin/gh" || fixture_die "cannot write $L25/bin/gh"
must chmod +x "$L25/bin/gh"

out="$(HOMEOSTASIS_GH=off run_hs "$L25" "$L25/primary" "$L25/primary/scripts/homeostasis" --apply)"
rc=$?
assert_exit "$rc" 1 "with gh off and no opt-in, the worktree is INCONCLUSIVE (exit 1)"
assert_contains "$out" "PR-awareness is OFF" "one clear line says PR-awareness is off"
assert_contains "$out" "$L25/wt-sibling  [feat/sibling]  open-PR state unknown" "the worktree is INCONCLUSIVE with the reason"
assert_dir_exists "$L25/wt-sibling" "nothing is removed without PR information"
assert_contains "$(report_section "$out" 5b)" "skipped (gh is off" "section 5b is skipped, not a violation"
assert_not_contains "$out" "gh must not be called" "gh is never invoked when off"

out="$(HOMEOSTASIS_GH=off HOMEOSTASIS_TRUST_NO_PRS=1 run_hs "$L25" "$L25/primary" "$L25/primary/scripts/homeostasis" --apply)"
rc=$?
assert_contains "$out" "*** HOMEOSTASIS_TRUST_NO_PRS=1" "the opt-in prints a loud banner"
assert_dir_missing "$L25/wt-sibling" "with the opt-in, a finished worktree is removable"
assert_exit "$rc" 0 "and the slate is clean afterwards"

# --- 26. CLI surface ----------------------------------------------------------

echo "26. --version, --help, unknown argument, outside a repository"
L26="$TMPROOT/cli"
must mkdir -p "$L26/bin" "$L26/not-a-repo"
out="$(run_hs "$L26" "$L26/not-a-repo" "$SUBJECT" --version)"
rc=$?
assert_exit "$rc" 0 "--version exits 0"
assert_contains "$out" "claude-homeostasis 0.1.1" "--version names the project and version"
out="$(run_hs "$L26" "$L26/not-a-repo" "$SUBJECT" --help)"
rc=$?
assert_exit "$rc" 0 "--help exits 0"
assert_contains "$out" "HOMEOSTASIS_TRUST_NO_PRS" "--help documents the configuration"
out="$(run_hs "$L26" "$L26/not-a-repo" "$SUBJECT" --bogus)"
rc=$?
assert_exit "$rc" 2 "an unknown argument exits 2"
out="$(GIT_CEILING_DIRECTORIES="$L26" run_hs "$L26" "$L26/not-a-repo" "$SUBJECT" --check)"
rc=$?
assert_exit "$rc" 2 "outside a git working tree exits 2"
assert_contains "$out" "not inside a git working tree" "with a clear message"

# --- 27. worktrees nested in the primary are not "untracked files" ------------
#
# Claude Code puts agent worktrees under .claude/worktrees/ INSIDE the repo. If
# that directory is not gitignored, git reports each worktree as an untracked
# path of the primary, so every live agent made section 2/3 cry wolf. Every
# worktree is already accounted for by section 4 (registered) or section 6
# (debris), so section 2/3 must not report them a second time; anything ELSE
# untracked (a stray file beside them, a loose file inside the worktrees dir)
# must still be reported.

echo "27. worktrees nested inside the primary are not reported as untracked paths"
L27="$TMPROOT/nested"
must mkdir -p "$L27"
make_layout "$L27"
clear_layout "$L27"
printf 'vendor/\nnode_modules/\n' > "$L27/primary/.gitignore" || fixture_die "cannot rewrite .gitignore"
must git -C "$L27/primary" commit -q -am 'stop ignoring worktree dirs'
must git_quiet -C "$L27/primary" push -q origin main
must git -C "$L27/primary" worktree add -q "$L27/primary/.claude/worktrees/agent-1" -b feat/agent-1
must git -C "$L27/primary" worktree add -q "$L27/primary/elsewhere/wt-2" -b feat/wt-2
must mkdir -p "$L27/primary/.claude/worktrees/ghost/vendor"
printf 'x\n' > "$L27/primary/.claude/worktrees/ghost/vendor/lib.txt" || fixture_die "cannot write ghost"

# report_section cannot take "2/3" (the slash ends its sed address), so this
# section is cut out directly — and an empty cut fails loudly, because every
# assert_not_contains below would pass vacuously on an empty string.
primary_tree_section() {
    local s=''
    s="$(printf '%s\n' "$1" | sed -n '/^== 2\/3\./,/^== 4\./p')"
    [ -n "$s" ] || fail "section 2/3 could not be extracted from the report"
    printf '%s\n' "$s"
}

out="$(run_hs "$L27" "$L27/primary" "$L27/primary/scripts/homeostasis" --check)"
sec="$(primary_tree_section "$out")"
assert_contains "$sec" "untracked paths: none (ok)" "nested worktrees and debris are not untracked paths of the primary"
assert_contains "$(report_section "$out" 4)" "$L27/primary/.claude/worktrees/agent-1" "the nested worktree is still reported in section 4"
assert_contains "$(report_section "$out" 4)" "$L27/primary/elsewhere/wt-2" "a worktree nested outside the worktrees dir is still reported in section 4"
assert_contains "$(report_section "$out" 6)" "ghost" "the debris directory is still reported in section 6"

printf 'note\n' > "$L27/primary/.claude/settings.local.json" || fixture_die "cannot write stray"
printf 'loose\n' > "$L27/primary/.claude/worktrees/stray.txt" || fixture_die "cannot write loose file"
printf 'loose\n' > "$L27/primary/elsewhere/stray2.txt" || fixture_die "cannot write loose file"
out="$(run_hs "$L27" "$L27/primary" "$L27/primary/scripts/homeostasis" --check)"
sec="$(primary_tree_section "$out")"
# git reports an untracked directory collapsed (`.claude/`, `elsewhere/`), not
# file by file, so those two are asserted as whole lines; the loose file inside
# the worktrees dir is named by the script itself, so its full path is asserted.
assert_line() {
    if printf '%s\n' "$1" | sed 's/^ *//' | grep -Fx -- "$2" >/dev/null; then pass "$3"; else fail "$3 (expected a line: $2)"; fi
}
assert_line "$sec" ".claude/" "a stray file beside the worktrees dir is still reported (as .claude/)"
assert_line "$sec" ".claude/worktrees/stray.txt" "a loose file inside the worktrees dir is still reported by name"
assert_line "$sec" "elsewhere/" "a loose file beside a nested worktree is still reported (as elsewhere/)"
assert_contains "$sec" "VIOLATION: 3 untracked path(s)" "exactly those three, and nothing for the worktrees themselves"

# A loose file the repo deliberately ignores is not drift.
printf '.claude/worktrees/stray.txt\n' >> "$L27/primary/.git/info/exclude" || fixture_die "cannot write info/exclude"
out="$(run_hs "$L27" "$L27/primary" "$L27/primary/scripts/homeostasis" --check)"
sec="$(primary_tree_section "$out")"
assert_not_contains "$sec" "stray.txt" "an ignored loose file inside the worktrees dir is not reported"
assert_not_contains "$sec" "agent-1" "the worktree itself is still not reported as untracked"
assert_not_contains "$sec" "ghost" "the debris directory is still not reported as untracked"

# --- summary ------------------------------------------------------------------

echo
TOTAL=$((PASS + FAIL))
echo "$PASS passed / $TOTAL total ($FAIL failed)"
[ "$FAIL" -eq 0 ]
