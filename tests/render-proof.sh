#!/usr/bin/env bash
#
# Proves the review pane actually PAINTS: a hermetic thurbox in a tmux pane,
# a real session with a real worktree and a real base branch, driven by keys,
# with the frames captured as text.
#
# `plugin check` loads the interface but never calls `render`, so this is the
# only thing that can tell a pane that draws from a pane that throws.
set -euo pipefail

# The thurbox checkout to build the kernel from. `thurbox-cli plugin` does not
# exist in a released 1.x binary, and this needs a v2 kernel anyway.
REPO_ROOT="${THURBOX_REPO:?set THURBOX_REPO to a thurbox checkout with target/debug built}"
# A scratch interface: the shipped `ui/` copied out of the checkout, with this
# repository symlinked in and named by a plugins.toml entry. Never inside either
# working copy — a dirty tree is what makes `plugin update` refuse to move.
UI_DIR="${THURBOX_UI_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/thurbox-code-review/ui}"
OUT="${OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/thurbox-code-review/frames}"
SOCKET="review-proof"
SESSION="review-proof"
COLS="${COLS:-160}"
ROWS="${ROWS:-45}"

mkdir -p "$OUT"
rm -f "$OUT"/*.txt

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v tmux >/dev/null || die "tmux not found"
[ -x "$REPO_ROOT/target/debug/thurbox" ] || die "build the checkout first"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$UI_DIR/thurbox-code-review" ]; then
  log "seeding a scratch interface at $UI_DIR"
  mkdir -p "$UI_DIR"
  cp -r "$REPO_ROOT/ui/layout.lua" "$REPO_ROOT/ui/lib" "$REPO_ROOT/ui/plugins" "$UI_DIR"/
  ln -sfn "$HERE" "$UI_DIR/thurbox-code-review"
  cat > "$UI_DIR/plugins.toml" <<TOML
# Development spec: the working copy is symlinked in, so an edit to the
# repository is live here without a reinstall. \`file\` is what the loader reads
# for a pane outside \`plugins/\` — see kernel::host, the \`nested\` list.
[[plugin]]
src  = "git+file://$HERE"
file = "thurbox-code-review/plugins/40_review.lua"
TOML
fi

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/dev/lib/sandbox-env.sh"
tbx_sandbox_init_full fresh

# Full isolation moves XDG_CACHE_HOME, so name the interface absolutely and
# after init — THURBOX_UI_DIR wins over every other rule.
export THURBOX_UI_DIR="$UI_DIR"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  tbx_sandbox_teardown
}
trap cleanup EXIT INT TERM

# --- an agent that is just a shell, so nothing tries to authenticate ---------
mkdir -p "$XDG_CONFIG_HOME/thurbox-dev"
cat > "$XDG_CONFIG_HOME/thurbox-dev/agents.toml" <<'TOML'
config_version = 1
default = "sh"

[[agents]]
name = "sh"
command = "bash"
args = []
TOML

# --- a repository with something to review ----------------------------------
WORK="$TBX_SANDBOX_ROOT/demo"
mkdir -p "$WORK"
cd "$WORK"
git init -q -b main .
git config user.email proof@example.com
git config user.name Proof
mkdir -p src/deep/nested docs
cat > src/one.lua <<'EOF'
local function greet(name)
  return "hello " .. name
end
return greet
EOF
cat > src/deep/nested/two.rs <<'EOF'
fn main() {
    println!("one");
}
EOF
cat > docs/notes.md <<'EOF'
# Notes
first
EOF
printf 'to be deleted\n' > docs/old.md
git add -A && git commit -qm "base"

log "creating the session"
"$REPO_ROOT/target/debug/thurbox-cli" session create \
  --name review-demo --repo-path "$WORK" \
  --worktree-branch feat/demo --base-branch main --agent sh --json > "$OUT/session.json"
WORKTREE="$(python3 -c "import json,sys;d=json.load(open('$OUT/session.json'));print(d.get('cwd') or d.get('session',{}).get('cwd',''))")"
[ -n "$WORKTREE" ] || { cat "$OUT/session.json"; die "no worktree path in the create output"; }
log "worktree: $WORKTREE"

# --- commit changes on the branch, so base..HEAD is non-empty ---------------
cd "$WORKTREE"
git config user.email proof@example.com
git config user.name Proof
cat > src/one.lua <<'EOF'
local function greet(name)
  -- a comment beginning with two dashes, so a deletion of it renders as `--- …`
  return "hello, " .. name .. "!"
end
local very_long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa é ─ ╭"
return greet, very_long
EOF
cat > src/deep/nested/two.rs <<'EOF'
fn main() {
    println!("two");
    println!("three");
}
EOF
printf 'brand new\n' > src/added.txt
git rm -q docs/old.md
git mv docs/notes.md docs/renamed.md
printf 'second\n' >> docs/renamed.md
git add -A && git commit -qm "the changes under review"

log "launching the TUI (${COLS}x${ROWS})"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" \
  "$REPO_ROOT/target/debug/thurbox"

capture() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION"; }
send() { tmux -L "$SOCKET" send-keys -t "$SESSION" "$@"; }

wait_for() {
  local needle="$1" tries="${2:-80}"
  for _ in $(seq 1 "$tries"); do
    if capture | grep -qF "$needle"; then return 0; fi
    sleep 0.15
  done
  capture > "$OUT/timeout.txt"
  die "timed out waiting for: $needle (frame in $OUT/timeout.txt)"
}

shot() {
  sleep "${2:-0.6}"
  capture > "$OUT/$1.txt"
  # The status band names the focused pane, which is the diagnostic that told
  # the first run a stray Escape had handed focus back to the agent.
  local who
  who="$(tail -1 "$OUT/$1.txt" | sed -n 's/^ *\([A-Za-z]*\) .*/\1/p')"
  log "captured $1  (focus: ${who:-?})"
}

# Wait for the first paint of anything, whichever screen it is.
seen() {
  local needle="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    if capture | grep -qF "$needle"; then return 0; fi
    sleep 0.15
  done
  return 1
}

# The v2 splash, shown once per profile. It lists "code review  Ctrl+X / F7 —
# nothing yet", which is the thing this run is about to disprove.
if seen "continue to v2" 60; then
  capture > "$OUT/00-splash.txt"
  send Enter
  sleep 0.8
fi

wait_for "review-demo"
shot 00-start

# F7 — v1's chord, and the one that reaches a pane from a focused terminal.
send F7
shot 01-review

send j; send j; send j; send j; send j; send j
shot 02-moved

send Tab
shot 03-next-file

send w
shot 04-wrapped

send w
send l; send l
shot 05-scrolled-right

send h; send h
# `greet` contains an `r`, which this pane binds to refresh. Typing it is the
# regression this frame exists for.
send /
send -l "greet"
shot 06-find 1.0

send Enter
shot 07-find-committed

send n
shot 08-find-next

send m
shot 09-marked

send G
shot 10-bottom

send BTab
shot 11-previous-file

send f
shot 12-files-hidden

send f
send g
send r
shot 13-refreshed 1.5

send e
shot 14-sent 1.5

# ── the states that are not a diff ──────────────────────────────────────────

# `pending`: caught by asking for a refresh and capturing before the worker
# answers. The point of the frame is that it does NOT read as a clean worktree.
send F7
send r
# Raced rather than delayed: on a repository this small the worker answers in
# milliseconds, so any fixed sleep catches the finished diff instead. `catch` is
# defined below, with the large-diff scenario it was written for.
catch_small() {
  local frame
  for _ in $(seq 1 800); do
    frame="$(capture)"
    if printf '%s' "$frame" | grep -qF "Building diff"; then
      printf '%s\n' "$frame" > "$OUT/20-pending.txt"
      log "captured 20-pending (caught it)"
      return 0
    fi
  done
  printf '%s\n' "$frame" > "$OUT/20-pending.txt"
  log "captured 20-pending (MISSED — this repository is too small to be slow)"
}
catch_small

# `ready` with nothing in it: a second session whose branch is its base.
log "a session with no changes"
"$REPO_ROOT/target/debug/thurbox-cli" session create \
  --name no-changes --repo-path "$WORK" \
  --worktree-branch feat/empty --base-branch main --agent sh --json > "$OUT/empty.json"
sleep 1.5
send C-j            # next session in the list
shot 21-no-changes 1.5

send C-k
shot 22-back

# Narrow: the files column is dropped, and the pane decides that from the width
# it was given.
tmux -L "$SOCKET" resize-window -t "$SESSION" -x 96 -y 30 2>/dev/null \
  || tmux -L "$SOCKET" resize-pane -t "$SESSION" -x 96 -y 30
shot 23-narrow 1.2

tmux -L "$SOCKET" resize-window -t "$SESSION" -x 60 -y 24 2>/dev/null \
  || tmux -L "$SOCKET" resize-pane -t "$SESSION" -x 60 -y 24
shot 24-very-narrow 1.2

tmux -L "$SOCKET" resize-window -t "$SESSION" -x "$COLS" -y "$ROWS" 2>/dev/null || true
sleep 0.8

# ── a diff big enough to be slow, and big enough to be capped ───────────────
#
# The small repository above answers faster than a capture can run, so `pending`
# and the incremental parse are unobservable there. This one is 400 files of 400
# lines, entirely rewritten: ~320k diff lines, well past the kernel's 4 MiB cap.
log "building a large repository"
BIG="$TBX_SANDBOX_ROOT/big"
mkdir -p "$BIG"
cd "$BIG"
git init -q -b main .
git config user.email proof@example.com
git config user.name Proof
python3 - <<'PYGEN'
import os
for f in range(400):
    d = f"pkg/mod{f // 20:02d}"
    os.makedirs(d, exist_ok=True)
    with open(f"{d}/file{f:03d}.txt", "w") as fh:
        fh.write("".join(f"module {f} original line {i} with a reasonable amount of text on it\n" for i in range(400)))
PYGEN
git add -A && git commit -qm "base"

"$REPO_ROOT/target/debug/thurbox-cli" session create \
  --name big-diff --repo-path "$BIG" \
  --worktree-branch feat/big --base-branch main --agent sh --json > "$OUT/big.json"
BIGTREE="$(python3 -c "import json;d=json.load(open('$OUT/big.json'));print(d.get('cwd') or d.get('session',{}).get('cwd',''))")"
cd "$BIGTREE"
git config user.email proof@example.com
git config user.name Proof
python3 - <<'PYGEN'
import os
for f in range(400):
    d = f"pkg/mod{f // 20:02d}"
    with open(f"{d}/file{f:03d}.txt", "w") as fh:
        fh.write("".join(f"module {f} REWRITTEN line {i} with a reasonable amount of text on it\n" for i in range(400)))
PYGEN
git add -A && git commit -qm "rewrite everything"
log "big diff: $(git diff --no-color main..HEAD | wc -c) bytes"

# Select it, and race the worker for the states it passes through on the way.
#
# Held in a variable and written only on a match: writing every candidate frame
# to disk made each poll slow enough that the worker finished between two of
# them, and a state that IS rendered was reported missing.
catch() {
  local name="$1" pattern="$2" tries="${3:-2000}" frame
  for _ in $(seq 1 "$tries"); do
    frame="$(capture)"
    if printf '%s' "$frame" | grep -qE "$pattern"; then
      printf '%s\n' "$frame" > "$OUT/$name.txt"
      log "captured $name (caught it)"
      return 0
    fi
  done
  printf '%s\n' "$frame" > "$OUT/$name.txt"
  log "captured $name (MISSED — the worker won the race; the frame is the state after)"
  return 1
}

send C-j; send C-j
catch 30-big-pending "Building diff|Asking for the diff" || true
catch 31-big-reading "reading [0-9]+%" || true

shot 32-big-ready 3.0
send G
shot 33-big-bottom 2.0
send g
shot 34-big-top 1.0

log "frames in $OUT"
