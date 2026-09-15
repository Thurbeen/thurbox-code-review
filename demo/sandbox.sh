#!/usr/bin/env bash
# Build a throwaway thurbox with the review pane installed, and print its root.
#
# Nothing here can touch a real interface, a real database or a real tmux
# server: HOME and every XDG root point at a fresh directory, and TMUX_TMPDIR
# gives the server its own socket directory — the socket NAME is shared by every
# thurbox of the same build, so without that a teardown would kill sessions you
# have running.
#
# The pane is installed the way the README says, with `plugin install`, from a
# clone of this repository's COMMITTED state — so what a recording shows is what
# a user gets, not the working tree. The clone is named `thurbox-code-review`
# because install names the directory after the source, and the pane requires its
# modules by that name.
#
#   demo/sandbox.sh
#
# Prints the sandbox root on stdout. The caller owns teardown:
#   TMUX_TMPDIR=<root>/tmux tmux -L thurbox kill-server; rm -rf <root>
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
command -v "$CLI" >/dev/null || { echo "no thurbox-cli on PATH (set THURBOX_CLI)" >&2; exit 2; }
command -v sqlite3 >/dev/null || { echo "sqlite3 is needed to skip the first-launch gate" >&2; exit 2; }

# Not /tmp: it is RAM on plenty of machines, and a recording leaves a cast behind.
ROOT=${DEMO_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/thurbox-code-review-demo}
mkdir -p "$ROOT"
S=$(mktemp -d "$ROOT/sandbox.XXXXXX")
# Until the root is printed the caller cannot tear it down, and `session create`
# has already started a tmux server by the time most of what follows can fail.
trap 'TMUX_TMPDIR="$S/tmux" tmux -L thurbox kill-server 2>/dev/null; rm -rf "$S"' ERR
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux"
# These win over XDG, so an inherited one would point the sandbox at a real
# config or a real interface.
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR THURBOX_UI_DIR
mkdir -p "$XDG_CONFIG_HOME/thurbox" "$XDG_DATA_HOME/thurbox" "$TMUX_TMPDIR"

# A stub agent that shows what it is sent: `cat` with the terminal echoing, so
# the review arrives on screen the way an agent would read it, with no agent CLI
# and no account. `-echoctl` because a send is a bracketed paste, and echoed as
# control characters its markers print as `^[[200~` around the review.
cat > "$XDG_CONFIG_HOME/thurbox/agents.toml" <<'AGENTS'
default = "agent"

[[agents]]
name = "agent"
command = "sh"
args = ["-c", "stty -echoctl; exec cat >/dev/null"]
AGENTS

git_demo() { git -c user.email=demo@example.com -c user.name=demo "$@"; }

# A small project with a small, realistic change on a branch.
P="$S/weather-cli"
mkdir -p "$P/weather" "$P/tests"
cat > "$P/README.md" <<'EOF'
# weather-cli

Prints the forecast for a city.
EOF
cat > "$P/weather/cache.py" <<'EOF'
"""An in-memory cache for forecast lookups."""


class Cache:
    def __init__(self):
        self._items = {}

    def get(self, key):
        return self._items.get(key)

    def put(self, key, value):
        self._items[key] = value
EOF
cat > "$P/weather/client.py" <<'EOF'
import json
import urllib.request

from weather.cache import Cache

API = "https://forecast.example.com/v1"


def forecast(city, cache=Cache()):
    hit = cache.get(city)
    if hit is not None:
        return hit
    with urllib.request.urlopen(f"{API}/{city}") as response:
        data = json.load(response)
    cache.put(city, data)
    return data
EOF
git init -q -b main "$P"
git_demo -C "$P" add -A
git_demo -C "$P" commit -qm "forecast lookups with a cache"

"$CLI" session create --name cache-expiry --repo-path "$P" \
    --worktree-branch feat/cache-expiry --base-branch main --json >"$S/session.json"
W=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cwd') or d['session']['cwd'])" "$S/session.json")

cat > "$W/weather/cache.py" <<'EOF'
"""An in-memory cache for forecast lookups."""

import time

# A forecast is stale after ten minutes.
DEFAULT_TTL = 600


class Cache:
    def __init__(self, ttl=DEFAULT_TTL, clock=time.monotonic):
        self._items = {}
        self._ttl = ttl
        self._clock = clock

    def get(self, key):
        entry = self._items.get(key)
        if entry is None:
            return None
        value, stored_at = entry
        if self._clock() - stored_at > self._ttl:
            del self._items[key]
            return None
        return value

    def put(self, key, value):
        self._items[key] = (value, self._clock())
EOF
cat > "$W/weather/client.py" <<'EOF'
import json
import urllib.request

from weather.cache import Cache

API = "https://forecast.example.com/v1"
_cache = Cache()


def forecast(city, cache=None):
    cache = cache or _cache
    hit = cache.get(city)
    if hit is not None:
        return hit
    with urllib.request.urlopen(f"{API}/{city}", timeout=5) as response:
        data = json.load(response)
    cache.put(city, data)
    return data
EOF
mkdir -p "$W/tests"
cat > "$W/tests/test_cache.py" <<'EOF'
from weather.cache import Cache


def test_an_entry_expires():
    now = [0.0]
    cache = Cache(ttl=10, clock=lambda: now[0])
    cache.put("oslo", "rain")
    now[0] = 11
    assert cache.get("oslo") is None
EOF
git_demo -C "$W" add -A
git_demo -C "$W" commit -qm "expire cached forecasts"

# Installed from committed state, under the name the pane requires itself by.
git clone -q "$REPO" "$S/src/thurbox-code-review"
"$CLI" plugin install "git+file://$S/src/thurbox-code-review" >/dev/null

# The first launch asks whether to continue to v2 and waits for an answer. A
# recording is about the pane, so the answer is recorded up front.
sqlite3 "$XDG_DATA_HOME/thurbox/thurbox.db" \
    "INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1')
     ON CONFLICT(key) DO UPDATE SET value = '1';"

"$CLI" plugin check --text >&2
echo "$S"
