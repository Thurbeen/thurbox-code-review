#!/usr/bin/env bash
# Record media/demo.gif: the real TUI, in a throwaway thurbox this agent pane was
# installed into (demo/sandbox.sh).
#
# asciinema records the pty and agg rasterises the cast — not VHS, which drives
# a headless browser and cannot send an F-key, and F7 is the way onto the tab.
# tmux is what presses the keys, so what lands in the cast is the interface
# reacting to real chords.
#
# Needs: asciinema, agg, tmux, git, sqlite3, python3, and thurbox + thurbox-cli
# on PATH.
#
#   demo/record.sh [output.gif]
#
# SNAP=<dir> writes what the screen held at each step, which is the only way to
# tell a key that missed from a key that landed on the wrong row: the cast is
# gone with the sandbox by the time the GIF looks wrong.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/media/demo.gif}
THURBOX=${THURBOX:-thurbox}
COLS=${COLS:-112}
ROWS=${ROWS:-30}
SNAP=${SNAP:-}

missing=
for tool in asciinema agg tmux git sqlite3 python3 "$THURBOX"; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
done
[ -n "$missing" ] && { echo "missing:$missing" >&2; exit 2; }

S=$("$REPO/demo/sandbox.sh")
TM=(tmux -L review-demo)
cleanup() {
    TMUX_TMPDIR="$S/tmux" "${TM[@]}" kill-server 2>/dev/null || true
    TMUX_TMPDIR="$S/tmux" tmux -L thurbox kill-server 2>/dev/null || true
    rm -f "$(cat "$S/data-link")"
    rm -rf "$S"
}
trap cleanup EXIT INT TERM

cat > "$S/run.sh" <<RUN
#!/usr/bin/env bash
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$(cat "$S/data-link")"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux" TERM=xterm-256color COLORTERM=truecolor
# The Shell tab starts \$SHELL. Pinned, so the recording shows a plain prompt
# rather than the recording machine's shell and its first-run setup, or a
# prompt carrying a user and host name.
export SHELL=/bin/sh PS1='\$ '
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR
cd "$S/weather-cli"
exec $(command -v "$THURBOX")
RUN
chmod +x "$S/run.sh"

export TMUX_TMPDIR="$S/tmux"
CAST="$S/demo.cast"
"${TM[@]}" new-session -d -x "$COLS" -y "$ROWS" \
    "asciinema rec --overwrite --quiet --command '$S/run.sh' '$CAST'"

# One key, then a pause long enough to read what it did.
k() { "${TM[@]}" send-keys -t 0 "$1"; sleep "${2:-0.6}"; }
# Typed a character at a time, at a pace a person types, so the note is seen
# being written rather than appearing.
type_slowly() {
    local text=$1 i
    for ((i = 0; i < ${#text}; i++)); do
        "${TM[@]}" send-keys -t 0 -l "${text:i:1}"
        sleep 0.035
    done
}
snap() { [ -n "$SNAP" ] && "${TM[@]}" capture-pane -p -t 0 >"$SNAP/$1.txt"; true; }
[ -n "$SNAP" ] && mkdir -p "$SNAP"

# Wait for the first frame rather than guessing.
for _ in $(seq 1 60); do
    "${TM[@]}" capture-pane -p -t 0 2>/dev/null | grep -q 'cache-expiry' && break
    sleep 0.5
done
sleep 1.2
snap 0-start

# The strip: Agent / Shell / Review, three tabs of one pane. F8 is the shell the
# pane always had; F7 is the review beside it.
k F8 1.2
snap 0-shell
k F7 1.6
snap 1-review

# Ctrl+H / Ctrl+L walk the panes, and the review is not one of them: focus goes to
# the session list and back, and the review never leaves the screen.
k C-h 0.9
snap 1-ring-sessions
k C-l 0.9
snap 1-ring-back

# The next file, and into its first change: `]` lands on the hunk header, and
# six rows down is `DEFAULT_TTL = 600`.
k Tab 1
snap 2-next-file
k ']' 0.6
k j 0.15; k j 0.15; k j 0.15; k j 0.15; k j 0.15; k j 0.8
snap 3-on-a-line

# A note on the line under the cursor, classified as an issue.
k c 0.4
type_slowly "is ten minutes right for every city?"
sleep 0.5
k Tab 0.6 # the classification cycles: praise
k Tab 1   # issue
snap 4-composing
k Enter 1.2
snap 5-noted

# Send it to the agent, which is where a review goes — and the pane shows the
# Agent tab, to watch it arrive.
k e 2.5
snap 7-sent

# Quit, which is what ends the recording: asciinema writes the cast when the
# command it wrapped exits.
k C-q 3
for _ in $(seq 1 20); do [ -s "$CAST" ] && break; sleep 1; done

# A GIF loops, so its last frame is on screen as long as any other. Quitting
# leaves a bare terminal there, so the cast is cut where teardown starts: the
# alternate screen going away is the first byte of the exit, and everything from
# there on is dropped. Not the cursor coming back — thurbox shows it while a note
# is being typed, and cutting there ended the recording mid-sentence.
python3 - "$CAST" <<'TRIM'
import json, sys

path = sys.argv[1]
lines = open(path).read().splitlines()
for i, line in enumerate(lines[1:], start=1):  # line 0 is the header
    data = json.loads(line)[2]
    if "\x1b[?1049l" in data:
        open(path, "w").write("\n".join(lines[:i]) + "\n")
        break
TRIM

# The GIF is published. Refuse to render one that carries anything identifying
# the machine it was made on. The sandbox root is under the real home directory,
# so a path leaking through anywhere in the interface would carry it.
python3 - "$CAST" "$(id -un)" "$(uname -n)" "$REPO" "$(dirname "$S")" <<'PRIVATE'
import json, sys

path, *needles = sys.argv[1:]
text = "".join(json.loads(line)[2] for line in open(path).read().splitlines()[1:])
found = [n for n in needles if n and n in text]
if found:
    sys.exit(f"the recording contains {found!r}; not rendering it")
PRIVATE

mkdir -p "$(dirname "$OUT")"
agg --font-size 16 --idle-time-limit 2 --last-frame-duration 3 "$CAST" "$OUT"
ls -lh "$OUT"
