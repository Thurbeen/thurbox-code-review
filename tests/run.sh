#!/usr/bin/env bash
#
# The pure modules — the parser, the row window, the export — under a real Lua
# 5.4, with the thurbox interface's own `lib.theme` and `lib.widgets` so that
# measurement and truncation behave exactly as they do in the pane. Only the
# `thurbox` snapshot is faked.
#
#   THURBOX_REPO=/path/to/thurbox tests/run.sh            # the checks
#   THURBOX_REPO=/path/to/thurbox tests/run.sh --measure  # the cost, in the
#                                                         # kernel's own unit
#
# The pane itself is not covered here: it needs the plugin VM and a rendered
# frame. `tests/render-proof.sh` is that half.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${THURBOX_REPO:?set THURBOX_REPO to a thurbox checkout}"
UI="$REPO/ui"

command -v lua >/dev/null || { echo "lua 5.4 not found" >&2; exit 1; }
[ -f "$UI/lib/widgets.lua" ] || { echo "no interface at $UI" >&2; exit 1; }

if [ "${1:-}" = "--measure" ]; then
  # Measured against the 4 MiB cap's worth of a real diff, cut on a line
  # boundary the way `kernel::diff::compute` cuts it. Any large diff will do;
  # pass one as DIFF, or take the checkout's own.
  CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/thurbox-code-review"
  mkdir -p "$CACHE"
  if [ -z "${DIFF:-}" ]; then
    DIFF="$CACHE/capped.diff"
    # `head -c` closes the pipe, so git takes a SIGPIPE and `pipefail` would
    # kill the script for doing exactly what was asked. The cut is the point.
    ( set +o pipefail
      cd "$REPO"
      git diff --no-color "$(git merge-base HEAD 1.x 2>/dev/null || echo HEAD~50)..HEAD" \
        | head -c 4194304 | head -n -1 > "$DIFF" )
  fi
  echo "measuring against $DIFF ($(wc -l < "$DIFF") lines)"
  REPO="$HERE" UI="$UI" DIFF="$DIFF" exec lua "$HERE/tests/measure.lua"
fi

REPO="$HERE" UI="$UI" exec lua "$HERE/tests/modules.lua"
