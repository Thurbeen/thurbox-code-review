#!/usr/bin/env bash
#
# Proves the agent pane wears thurbox v2.35's focus language in a real thurbox:
# thick `┏━┓` borders and a ` ▸ ` title mark on the focused pane, thin rounded
# ones on the other, and the terminal cursor painted only while the agent has
# the keys — on the Agent tab and on the Review tab, focused and not, beside the
# shipped session list, in four themes.
#
# `tests/agent.lua` asserts the tree the pane returns; this asserts what the
# kernel paints from it, which is the only place a border glyph or a cursor can
# be seen. The sandbox is `demo/sandbox.sh`'s: its own HOME, XDG roots and tmux
# socket directory, with the pane installed from this repository's COMMITTED
# state — commit before running it.
#
#   tests/focus-proof.sh
#   THEMES="default zenburn" tests/focus-proof.sh
#   STILLS=<dir> tests/focus-proof.sh     # also a PNG of every state, and a
#                                         # `-mono` copy with the colour stripped
#
# Needs thurbox + thurbox-cli v2.35 or later on PATH (THURBOX / THURBOX_CLI to
# name others), tmux, git, sqlite3 and python3; STILLS also needs asciinema's
# `agg` and ffmpeg.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
THURBOX=${THURBOX:-thurbox}
export THURBOX_CLI=${THURBOX_CLI:-thurbox-cli}
THEMES=${THEMES:-default github-light zenburn oxocarbon}
COLS=${COLS:-120}
ROWS=${ROWS:-30}
STILLS=${STILLS:-}

missing=
tools="tmux git sqlite3 python3 $THURBOX $THURBOX_CLI"
[ -n "$STILLS" ] && tools="$tools agg ffmpeg"
for tool in $tools; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
[ -n "$missing" ] && { echo "missing:$missing" >&2; exit 2; }
[ -n "$STILLS" ] && STILLS=$(mkdir -p "$STILLS" && cd "$STILLS" && pwd)

# These win over XDG, and a pane thurbox spawned inherits them, so an inherited
# one would point every command below at a real config, database, tmux server
# or interface.
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR THURBOX_SOCKET THURBOX_SOCKET_FOR \
  THURBOX_SESSION THURBOX_SESSION_ID
S=$("$REPO/demo/sandbox.sh" 2>/dev/null)
export TMUX_TMPDIR="$S/tmux"
TM=(tmux -L focus-proof)
cleanup() {
  "${TM[@]}" kill-server 2>/dev/null || true
  tmux -L thurbox kill-server 2>/dev/null || true
  rm -rf "$S"
}
trap cleanup EXIT INT TERM

sandboxed() {
  HOME="$S" XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share" \
    XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache" "$@"
}

cat >"$S/run.sh" <<RUN
#!/usr/bin/env bash
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux" TERM=xterm-256color SHELL=/bin/sh PS1='\$ '
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR THURBOX_SOCKET THURBOX_SOCKET_FOR \
  THURBOX_SESSION THURBOX_SESSION_ID
cd "$S/weather-cli"
exec $(command -v "$THURBOX")
RUN
chmod +x "$S/run.sh"

# Pinned, then read back through thurbox, so a theme that did not take fails
# here instead of being recorded as the fallback.
pin_theme() {
  sqlite3 "$S/.local/share/thurbox/thurbox.db" \
    "INSERT INTO metadata (key, value) VALUES ('active_theme', '$1')
     ON CONFLICT(key) DO UPDATE SET value = excluded.value"
  sandboxed "$THURBOX_CLI" config show --json | grep -q "\"theme\": *\"$1\"" \
    || { echo "the theme did not take: expected $1" >&2; exit 1; }
}

k() { "${TM[@]}" send-keys -t 0 "$1"; sleep "${2:-1}"; }
capture() { "${TM[@]}" capture-pane -p -t 0; }

failures=0
checks=0

# Split the screen's top border into the session list's and the agent pane's,
# and read the cues off each: the corner glyphs, the mark on the title, and
# whether the agent's first inner cell holds the cursor block. The session list
# is the left pane, so its top border ends at the first right-hand corner.
expect() { # expect <label> <agent: focused|unfocused> <tab: agent|review>
  local label=$1 want=$2 tab=$3 verdict
  checks=$((checks + 1))
  verdict=$(capture | python3 -c '
import sys
want, tab = sys.argv[1], sys.argv[2]
lines = sys.stdin.read().split("\n")
top = next(i for i, line in enumerate(lines) if line[:1] in "╭┏")
row = lines[top]
split = min(i for i, ch in enumerate(row) if ch in "╮┓") + 1
sessions, agent = row[:split], row[split:]
inner = lines[top + 1][split + 1 :]
cursor = inner[:1] == "█"
focused = want == "focused"
problems = []
if (agent[:1], agent[-1:]) != (("┏", "┓") if focused else ("╭", "╮")):
    problems.append(f"agent corners {agent[:1]}{agent[-1:]}")
if ("━" in agent) != focused:
    problems.append("agent rule " + ("thin" if focused else "thick"))
if ("▸" in agent) != focused:
    problems.append("agent mark " + ("missing" if focused else "present"))
if tab == "review" and "main..HEAD" not in agent:
    problems.append("no range on the review title")
if sessions[:1] != ("╭" if focused else "┏"):
    problems.append(f"session list corner {sessions[:1]}")
if tab == "agent" and cursor != focused:
    problems.append("cursor " + ("missing" if focused else "painted"))
if tab == "review" and cursor:
    problems.append("cursor painted over the review")
print("; ".join(problems) or "ok")
' "$want" "$tab")
  if [ "$verdict" = ok ]; then
    printf '  ok   %s\n' "$label"
  else
    failures=$((failures + 1))
    printf '  FAIL %s -- %s\n' "$label" "$verdict"
    capture | head -6 | sed 's/^/       | /' || true
  fi
}

# A PNG of the screen as tmux holds it: the cells with their colours and
# attributes, as a one-event cast rendered by agg. `-mono` drops every colour
# parameter and keeps bold and reverse — what a monochrome terminal is left with.
still() { # still <name> <thurbox theme>
  [ -n "$STILLS" ] || return 0
  local palette=asciinema mono
  case "$2" in *light* | *latte* | *day* | *dawn*) palette=github-light ;; esac
  "${TM[@]}" capture-pane -p -e -t 0 >"$S/still.ansi"
  for mono in 0 1; do
    python3 - "$S/still.ansi" "$COLS" "$ROWS" "$mono" >"$S/still.cast" <<'CAST'
import json, re, sys

path, cols, rows, mono = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
text = open(path, encoding="utf-8", errors="replace").read().rstrip("\n")


def strip(match):
    params = match.group(1).split(";") if match.group(1) else ["0"]
    kept, i = [], 0
    while i < len(params):
        p = params[i]
        if p in ("38", "48", "58"):
            i += 3 if i + 1 < len(params) and params[i + 1] == "5" else 5
            continue
        n = int(p) if p.isdigit() else 0
        if not (30 <= n <= 39 or 40 <= n <= 49 or 90 <= n <= 97 or 100 <= n <= 107):
            kept.append(p)
        i += 1
    return "\x1b[" + ";".join(kept) + "m" if kept else ""


if mono:
    text = re.sub(r"\x1b\[([0-9;]*)m", strip, text)
print(json.dumps({"version": 2, "width": cols, "height": rows}))
print(json.dumps([0.0, "o", "\x1b[?25l\x1b[H\x1b[2J" + text.replace("\n", "\r\n")]))
print(json.dumps([0.5, "o", ""]))
CAST
    agg --font-size 14 --theme "$palette" "$S/still.cast" "$S/still.gif" >/dev/null 2>&1
    ffmpeg -loglevel error -y -i "$S/still.gif" -frames:v 1 -update 1 \
      "$STILLS/$1$([ "$mono" = 1 ] && echo -mono).png"
  done
}

for theme in $THEMES; do
  echo "== $theme =="
  pin_theme "$theme"
  "${TM[@]}" new-session -d -x "$COLS" -y "$ROWS" "$S/run.sh"
  for _ in $(seq 1 60); do
    capture 2>/dev/null | grep -q 'cache-expiry' && break
    sleep 0.5
  done
  sleep 2

  # Boot focus is the agent pane.
  expect "$theme: the Agent tab, focused" focused agent
  still "$theme-1-agent-focused" "$theme"
  k C-h
  expect "$theme: the Agent tab, the session list focused" unfocused agent
  still "$theme-2-agent-unfocused" "$theme"
  k C-l
  k F7 2
  expect "$theme: the Review tab, focused" focused review
  still "$theme-3-review-focused" "$theme"
  k C-h
  expect "$theme: the Review tab, the session list focused" unfocused review
  still "$theme-4-review-unfocused" "$theme"
  # Each session keeps its tab, so the next theme starts on the agent again.
  k C-l
  k F7
  k C-q 1.5
  "${TM[@]}" kill-server 2>/dev/null || true
done

echo
echo "$checks checks, $failures failures"
[ "$failures" -eq 0 ]
