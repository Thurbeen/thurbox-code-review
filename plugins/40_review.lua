-- The code-review pane: a session's worktree against its base branch.
--
-- v1 shipped this natively — 1,844 lines of rendering and 2,610 of state — and
-- it went with `src/ui`. This is the plugin that pays it back, and it is the
-- first consumer of `thurbox.diffs` anywhere.
--
-- ── The shape, and why it is two shapes ─────────────────────────────────────
--
-- The pane is one plugin holding two very different things, which is design.md
-- D2 and the reason this pane is expressible at all:
--
--   the changed-files list is a TREE — rows with identity, so they can be
--     selected, clicked and decorated by a pane that never heard of this one;
--   the diff body is a SURFACE — cells positioned by character measurement
--     against the width the kernel resolved, so wrapping, horizontal scrolling
--     and colouring are all decisions made here from `ctx.width`.
--
-- D3 says the body needs no fifth node kind, and it does not: `text`, `box` and
-- `surface` draw everything below. If you find yourself wanting a fifth, you
-- have the split wrong — that is the whole claim this pane is the test of.
--
-- ── The rule that outranks everything else ──────────────────────────────────
--
--   ONE LOGICAL DIFF ROW IS ONE SELECTABLE UNIT.
--
-- Wrapping expands VISUAL rows only. The cursor, the scroll anchor, the
-- scrollbar and every hitbox are indices into the flat logical list that
-- `lib/diff.lua` builds; `lib/rows.lua` is the only file that knows a logical
-- row can occupy several lines. v1 held the same line across unified, wrapped
-- and side-by-side layouts, and it is what makes a comment anchor mean
-- something later.
--
-- ── What is missing, and why it is missing rather than faked ────────────────
--
-- Comments and review marks have storage in the kernel (`storage::review`,
-- `review_comments` / `review_marks`, schema v38) that survived the deletion of
-- v1's UI. None of it is published to Lua and there is no command to write one,
-- so this pane CANNOT persist a comment. It says so, once, rather than keeping
-- comments in `state` where they would look persistent and vanish on the next
-- upgrade. `KERNEL-GAPS.md` beside this file states the exact read and command
-- that would close it.

local hover = require("lib.hover")
local panels = require("lib.panels")
local theme = require("lib.theme")
local widgets = require("lib.widgets")

local diff = require("thurbox-code-review.lib.diff")
local rows = require("thurbox-code-review.lib.rows")
local export = require("thurbox-code-review.lib.export")
local syntax = require("thurbox-code-review.lib.syntax")

--- What this pane is called: the focus ring, `command("focus", …)`, and the
--- name a settings lookup filters on.
local NAME = "review"

--- The slot this pane occupies. Named once because two things need it: the
--- declaration at the bottom, and finding what else lives here.
local SLOT = "center"

--- Columns the changed-files list asks for, and the width below which the pane
--- stops offering it at all. Below `FILES_MIN_PANE` there is not room for a diff
--- and a list of what is in it, and the diff is the thing you came for.
local FILES_WIDTH_MAX, FILES_WIDTH_MIN, FILES_MIN_PANE = 34, 20, 70

--- Columns a horizontal scroll step moves. v1's, so the muscle memory carries.
local HSCROLL_STEP = 8

--- Rows a page key moves. Logical rows, not visual ones — a page that moved by
--- visual lines would move a different distance depending on how many lines
--- happened to be wrapped, which is the rule above leaking out through a key.
local PAGE = 10

local ROUNDED = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }

--- The pane this one displaces: the other occupant of its own slot.
---
--- v1's review is a TAB of the centre pane, so leaving it shows the terminal
--- again — not "whatever you were looking at before". In v2 it is a switch-slot
--- alternate, and `command("focus", { toggle = true })` returns to wherever
--- focus came from, which is the session list if that is where you pressed the
--- key. Same keystroke, different destination, and v1's is the one that matches
--- what a reviewer means by closing a review.
---
--- DERIVED, not named. Hard-coding `agent` would be asserting the default
--- arrangement, and the arrangement is the user's file — the exact objection
--- that made `toggle` a kernel primitive. But `thurbox.plugins` publishes every
--- pane's slot, so "what else lives in mine" is a question the interface can
--- answer about itself, and answering it is not the same as assuming it.
---
--- The first match wins, which is the rule the switch slot itself uses to choose
--- what it shows: load order, set by the numeric filename prefix. States that
--- cannot hold focus are skipped, so a disabled or unplaced sibling is never
--- handed a keystroke it would swallow.
local UNFOCUSABLE = {
  disabled = true,
  unplaced = true,
  removed = true,
  failed = true,
}

local function slot_mate()
  for _, entry in ipairs((thurbox and thurbox.plugins) or {}) do
    if
      entry.kind == "pane"
      and entry.slot == SLOT
      and entry.name ~= NAME
      and not UNFOCUSABLE[entry.state]
    then
      return entry.name
    end
  end
  return nil
end

--- Leave this pane, landing on whatever shares its slot.
---
--- Falls back to the kernel's toggle when there is nothing to land on — a lone
--- occupant, or an interface that published no inventory. Going back to where
--- focus came from is a worse answer than this one, and a much better one than
--- staying put.
local function leave()
  local mate = slot_mate()
  if mate then
    command("focus", { text = mate })
  else
    command("focus", { text = NAME, toggle = true })
  end
end

-- ── reading the world ───────────────────────────────────────────────────────

--- The session the list has selected, resolved against this frame's snapshot.
---
--- `store.selected` is the session list's own signal, and since the kernel fix
--- of 2026-08-18 it is also what drives the diff request — so a pane that shows
--- a diff and draws no terminal is now handed the thing it exists to show.
local function selected()
  local id = store.selected
  if not id then
    return nil
  end
  for _, session in ipairs(thurbox and thurbox.sessions or {}) do
    if session.id == id then
      return session
    end
  end
  return nil
end

--- What the kernel knows about that session's changes, or nil for "never asked".
local function published(session)
  if not session then
    return nil
  end
  return (thurbox and thurbox.diffs or {})[session.id]
end

-- ── the parse, and its epoch ────────────────────────────────────────────────
--
-- A diff's content can only change by the store dropping its entry and
-- recomputing, which means a frame that is not `ready` must pass between two
-- different bodies. Counting those transitions identifies a body exactly, at one
-- comparison per frame — where hashing 100k lines every frame to notice a change
-- that almost never happens would cost more than the parse it protects.

local epochs = {}
local seen_state = {}

--- Advance the epoch when a session's diff leaves the `ready` state, and return
--- the epoch in force.
local function epoch_of(id, state)
  local before = seen_state[id]
  if before == "ready" and state ~= "ready" then
    epochs[id] = (epochs[id] or 0) + 1
  end
  seen_state[id] = state
  return epochs[id] or 0
end

-- ── per-session cursor state ────────────────────────────────────────────────
--
-- Keyed per session for the reason the terminal pane keys its scrollback per
-- session: where you are in a review is a property of the review, not of the
-- pane looking at it. Shared, selecting another session would carry your cursor
-- onto a diff it means nothing in.
--
-- `state` hands back a COPY on every read, so every one of these writes the
-- whole value back. Mutating what a read returned changes nothing at all, which
-- is the first trap PLUGINS.md names.

local function cursor_of(id)
  return state["sel:" .. id] or 1
end

local function set_cursor(id, at)
  state["sel:" .. id] = at > 1 and at or nil
end

local function top_of(id)
  return state["top:" .. id] or 1
end

local function set_top(id, at)
  state["top:" .. id] = at > 1 and at or nil
end

local function hscroll_of(id)
  return state["hscroll:" .. id] or 0
end

local function set_hscroll(id, at)
  state["hscroll:" .. id] = at > 0 and at or nil
end

--- Where the changed-files list is pointing, when that is not simply "wherever
--- the body is".
---
--- `nil` means FOLLOW THE BODY, which is what it does almost all the time — the
--- list is a navigation aid, and an aid that drifts from the thing it is aiding
--- is a second thing to keep track of. It is set only when the list is driven
--- somewhere the body cannot go, which since `962aef7` is a real place: the
--- kernel lists every changed file and caps only the patch, so on a large diff
--- there are hundreds of files named in the list with no rows behind them.
---
--- Any movement of the BODY clears it, so the two can never silently disagree:
--- either you are driving the list, or the list is following you.
local function list_at(id)
  return state["list:" .. id]
end

local function set_list_at(id, path)
  state["list:" .. id] = path
end

--- Files marked reviewed, as `path -> true`.
---
--- TRANSIENT, and said to be transient in the footer. `review_marks` exists in
--- the kernel's storage and is not published, so this is a session-lifetime
--- convenience and not the persistence v1 had. Keeping it in `state` rather than
--- pretending otherwise is the honest half; the dishonest half would be leaving
--- the user to discover it after a restart.
local function marks_of(id)
  return state["marks:" .. id] or {}
end

local function toggle_mark(id, path)
  local held = marks_of(id)
  held[path] = (not held[path]) or nil
  state["marks:" .. id] = held
end

--- Files whose fold state is flipped from what their mark implies.
---
--- v1's `fold_override`, and v1's rule: a file is folded when
--- `reviewed XOR override`. Marking a file seen folds it, because the point of
--- marking it is that you are done with it — and the override lets you peek into
--- a file you have marked, or fold one you have not, without either changing the
--- mark. Two ideas, two sets, one XOR.
local function folds_of(id)
  return state["fold:" .. id] or {}
end

local function toggle_fold(id, path)
  local held = folds_of(id)
  held[path] = (not held[path]) or nil
  state["fold:" .. id] = held
end

--- Is this file collapsed to its header?
local function folded(marks, overrides, path)
  return (marks[path] == true) ~= (overrides[path] == true)
end

--- What the fold set and the layout amount to, for the row cache.
---
--- A string rather than a table so a comparison is one operation. Built from the
--- two sets rather than from the resulting fold state, because that is what
--- changes when a key is pressed.
local function fold_signature(marks, overrides, side)
  local parts = { side and "side" or "unified" }
  for path in pairs(marks) do
    parts[#parts + 1] = "m" .. path
  end
  for path in pairs(overrides) do
    parts[#parts + 1] = "o" .. path
  end
  table.sort(parts)
  return table.concat(parts, "\1")
end

-- ── the view toggles ────────────────────────────────────────────────────────
--
-- ONE source of truth: the declared setting, read from the registry and written
-- with `command("set", …)`.
--
-- The first version kept an override in `state` beside the setting, on the
-- reasoning that "the setting is what the pane starts as, the key is what you
-- did to it since". Both persist, so that bought nothing and cost the property
-- that matters: `Ctrl+,` showed a value the key had silently overridden, and
-- resetting it there did nothing. A knob with two homes is a knob that lies in
-- one of them.
--
-- `command("set", { text = "<plugin>.<id>", flag = … })` is the write. It takes
-- effect a frame later, like every command, which nobody can see.

local function toggle_value(id, declared)
  local registry = (thurbox and thurbox.registry and thurbox.registry.settings) or {}
  for _, entry in ipairs(registry) do
    if entry.plugin == NAME and entry.id == id then
      if entry.value ~= nil then
        return entry.value == true
      end
      return declared
    end
  end
  return declared
end

--- Flip a declared setting, and say what it will become.
local function set_toggle(id, declared)
  local now = not toggle_value(id, declared)
  command("set", { text = NAME .. "." .. id, flag = now })
  return now
end

local function wrapping()
  return toggle_value("wrap", false)
end

local function files_shown()
  return toggle_value("files", true)
end

--- Colour the code as well as the change.
---
--- On by default, as v1 has it. Off is a setting rather than a key: the keys are
--- crowded and this is a preference, not a thing you flip while reading.
local function highlighting()
  return toggle_value("syntax", true)
end

--- Unified, or old-and-new side by side. v1's `v`.
local function side_by_side()
  return toggle_value("side", false)
end

--- The rows in force: two flat lists over one parse, and which one is on screen
--- decides what a selectable unit IS. See `lib/diff.lua`'s pairing section.
local function rows_in_force(parse, id)
  local base = side_by_side() and diff.paired(parse) or parse.rows
  if not id then
    return base
  end
  local marks, overrides = marks_of(id), folds_of(id)
  if next(marks) == nil and next(overrides) == nil then
    -- Nothing folded: hand back the base list rather than a copy of it. This is
    -- the usual case and it should cost nothing.
    return base
  end
  return diff.unfolded(parse, base, function(path)
    return folded(marks, overrides, path)
  end, fold_signature(marks, overrides, side_by_side()) .. ":" .. parse.at)
end

-- ── find-in-diff ────────────────────────────────────────────────────────────
--
-- Per session, like the cursor and for the same reason. Held globally, a query
-- typed against one session followed you onto the next one and sat there saying
-- "no matches" about a diff you had never searched.

--- The session a key is acting on. `on_key` has no argument to derive it from,
--- and every find key needs it, so it is resolved the same way `render` does.
local function current_id()
  local session = selected()
  return session and session.id or nil
end

local function query(id)
  id = id or current_id()
  local text = id and state["query:" .. id]
  if text == nil or text == "" then
    return nil
  end
  return text
end

local function set_query(id, text)
  state["query:" .. id] = (text ~= nil and text ~= "") and text or nil
end

local function find_open(id)
  return id ~= nil and state["find:" .. id] == true
end

local function finding(id)
  id = id or current_id()
  return id ~= nil and state["typing:" .. id] == true
end

local function close_find(id)
  state["find:" .. id] = nil
  state["typing:" .. id] = nil
  state["query:" .. id] = nil
end

--- Logical rows whose text contains the query, in row order.
---
--- INCREMENTAL, for the reason the parse is. A full scan of a capped diff was
--- measured at 2.3M instructions and 32 ms — fine once, and paid on every frame
--- of the parse if the list were rebuilt whenever `rows` grew. Rows are only
--- ever appended, so the scan resumes from where it stopped and the whole parse
--- costs one pass however many frames it took.
---
--- Module-local for the reason the parse cache is: `state` and `store` hand back
--- a copy on every read, and this list can hold thousands of entries.
local match_cache = {}

local function matches(id, parse, in_force, needle)
  if not needle then
    return {}
  end
  -- Keyed on the LAYOUT as well: the two lists index differently, so a match
  -- list built against one is a set of wrong row numbers in the other.
  local layout = side_by_side() and "side" or "unified"
  local held = match_cache[id]
  if
    not (held and held.needle == needle and held.epoch == epochs[id] and held.layout == layout)
  then
    held = { needle = needle, epoch = epochs[id], layout = layout, scanned = 0, list = {} }
    match_cache[id] = held
  end
  local lowered = string.lower(needle)
  local list = held.list
  for at = held.scanned + 1, #in_force do
    if string.find(string.lower(rows.text_of(in_force[at], parse.rows)), lowered, 1, true) then
      list[#list + 1] = at
    end
  end
  held.scanned = #in_force
  return list
end

-- ── the session-column toggle on the border ─────────────────────────────────
--
-- v1 paints the collapse chevron on the LEFT of the central pane's top border,
-- and it is there on every central view — the review included. The agent pane
-- draws it in v2; this pane replacing the agent in the same slot must draw it
-- too, or `F9` and its arrow vanish from the screen for as long as you are
-- reading a diff. A affordance that exists on one occupant of a slot and not
-- the next is worse than one that exists on neither.
--
-- Duplicated from `20_agent.lua` rather than shared, for the reason that file
-- gives for duplicating `compact_chord`: a pane is meant to be replaceable on
-- its own, and a `lib` entry read by two panes makes swapping either one a
-- two-file edit.

--- Cells the padded chevron segment (` ◀ `) occupies, so the accent chevron and
--- the muted ` F9 ` hint are styled apart — v1 `COLLAPSE_CHEVRON_CELLS`.
local COLLAPSE_CHEVRON_CELLS = 3
--- v1 `COLLAPSE_TOGGLE_MIN_WIDTH`: narrower than this and even a bare chevron
--- has nowhere to go.
local COLLAPSE_TOGGLE_MIN_WIDTH = 5
--- v1 `COLLAPSE_HINT_MIN_WIDTH`: below it the toggle is chevron-only, to save
--- border space for the title.
local COLLAPSE_HINT_MIN_WIDTH = 40
--- The action the chevron performs. Named once: it is the click verb, the hover
--- key and what the shortcut is looked up by.
local COLLAPSE = "sessions.toggle_panel"

--- v1 renders a chord compactly: `^Q`, `⇧J`, `F7`. Mirrors `KeyChord::compact`.
local function compact_chord(chord)
  local modifiers, key = "", chord
  while true do
    local prefix, rest = string.match(key, "^(%a+)%+(.*)$")
    if not prefix then
      break
    end
    local symbol = ({ ctrl = "^", shift = "⇧", alt = "⌥", cmd = "⌘" })[prefix]
    if not symbol then
      break
    end
    modifiers = modifiers .. symbol
    key = rest
  end
  if widgets.len(key) == 1 then
    key = string.upper(key)
  elseif widgets.len(key) > 1 then
    key = string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
  end
  return modifiers .. key
end

--- The chord bound to an action, preferring a bare F-key.
---
--- Read from the registry rather than written here, so rebinding the toggle
--- relabels the border without this file knowing.
local function shortcut_for(action)
  local first
  for _, binding in ipairs((thurbox and thurbox.registry and thurbox.registry.keys) or {}) do
    if binding.action == action and binding.key then
      if string.match(binding.key, "^f%d+$") then
        return compact_chord(binding.key)
      end
      first = first or binding.key
    end
  end
  return first and compact_chord(first) or nil
end

--- v1 `session_collapse_toggle_label`: ` ◀ F9 ` while the list is shown
--- (collapse it leftward), ` ▶ F9 ` while hidden (expand it back). The chevron
--- points the way the list will move; the hint is dropped on a narrow pane.
local function collapse_label(width)
  if width < COLLAPSE_TOGGLE_MIN_WIDTH then
    return nil
  end
  local chevron = panels.shown("sessions") and "◀" or "▶"
  local hint = width >= COLLAPSE_HINT_MIN_WIDTH and shortcut_for(COLLAPSE) or nil
  if hint then
    return " " .. chevron .. " " .. hint .. " "
  end
  return " " .. chevron .. " "
end

--- Keep the FIRST `max` characters, clipping the rest with no marker.
local function keep_left(text, max)
  if max <= 0 then
    return ""
  end
  if widgets.len(text) <= max then
    return text
  end
  return rows.slice(text, 1, max)
end

--- The chevron and its hint as border runs, both carrying the same click verb.
---
--- Two runs because a run is one node and a node has one style — the chevron
--- reads accent and the hint muted — but the SAME role, so the kernel hit-tests
--- them as one target. Without that the hint is inert: not clickable, and not
--- lit when the pointer is over it, which makes a six-cell label feel like it
--- has a three-cell hitbox in the middle.
local function collapse_runs(width)
  local label = collapse_label(width)
  if not label then
    return {}
  end
  -- v1: "a button by action but a bare border glyph by look", so both runs take
  -- the subtle band together — a filled pill here would invent a chip on the
  -- border where v1 draws none, and half a lit button is worse than none.
  local band = hover.role("action:" .. COLLAPSE) and theme.role("selection_bg") or nil
  local out = {
    {
      text = keep_left(label, COLLAPSE_CHEVRON_CELLS),
      style = { fg = theme.accent, bg = band },
      role = "action:" .. COLLAPSE,
    },
  }
  local hint = rows.slice(label, COLLAPSE_CHEVRON_CELLS + 1, widgets.len(label))
  if hint ~= "" then
    out[#out + 1] = {
      text = hint,
      style = { fg = theme.muted, bg = band },
      role = "action:" .. COLLAPSE,
    }
  end
  return out
end

--- The top border as a NODE, not a run list.
---
--- Identity is per NODE, so a chip painted as one span among many can never be a
--- click target however it is styled. When any run carries a `role`, the row
--- becomes a horizontal box of one text node per run, each with an exact `len`
--- so the geometry is bit-identical to the single-node form. `20_agent.lua`
--- learned this the hard way and its comment says so.
local function top_row_node(runs)
  local clickable = false
  for _, run in ipairs(runs) do
    if run.role then
      clickable = true
      break
    end
  end
  if not clickable then
    return { type = "text", len = 1, text = { runs } }
  end
  local children = {}
  for _, run in ipairs(runs) do
    local span = widgets.len(run.text)
    if span > 0 then
      children[#children + 1] = {
        type = "text",
        len = span,
        role = run.role,
        text = { { { text = run.text, style = run.style } } },
      }
    end
  end
  return { type = "box", axis = "horizontal", len = 1, children = children }
end

-- ── chrome ──────────────────────────────────────────────────────────────────

local function border_style(focused)
  return { fg = focused and theme.border_focused or theme.border }
end

--- Integer divide, rounding to nearest — ratatui's `rounding_divide`, so the
--- thumb lands where every other scrollbar in the interface puts it.
local function rounding_divide(numerator, denominator)
  return math.floor((numerator + math.floor(denominator / 2)) / denominator)
end

--- One run per inner row of a scrollbar over LOGICAL rows.
---
--- Over logical rows on purpose, and this is the rule showing up in the chrome:
--- a thumb scaled to visual lines would change size when you pressed `w`, as
--- though the diff had grown. It tracks the cursor rather than the scroll
--- offset, because the cursor reaches the last row and the offset never can.
local function scrollbar(height, total, position)
  local track = height - 2
  if total <= 0 or track <= 0 or total <= height then
    return nil
  end
  local highest = math.max(0, total - 1)
  local at = math.max(0, math.min(position, highest))
  local span = highest + height
  local thumb = math.max(1, math.min(rounding_divide(height * track, span), track))
  local start = math.max(0, math.min(rounding_divide(at * track, span), track - thumb))

  local rail = { text = "║", style = { fg = theme.muted } }
  local grip = { text = "█", style = { fg = theme.accent } }
  local out = { { text = "▲" } }
  for _ = 1, start do
    out[#out + 1] = rail
  end
  for _ = 1, thumb do
    out[#out + 1] = grip
  end
  for _ = 1, track - start - thumb do
    out[#out + 1] = rail
  end
  out[#out + 1] = { text = "▼" }
  return out
end

--- A bordered pane whose top border carries a left title and a right one, and
--- whose right border column can be replaced row by row (the scrollbar goes
--- there, so it costs no content column).
---
--- Drawn by hand rather than with `widgets.panel` because a framed node hands
--- its whole inner rect to one child, which forecloses both of those.
local function chrome(opts)
  local width, height = opts.width, opts.height
  if width < 4 or height < 3 then
    return opts.body
  end
  local edge = opts.border
  local inner_w, inner_h = width - 2, height - 2

  local left, right = opts.left or {}, opts.right or {}
  local used = 0
  for _, run in ipairs(left) do
    used = used + widgets.len(run.text)
  end
  local right_w = 0
  for _, run in ipairs(right) do
    right_w = right_w + widgets.len(run.text)
  end
  local top = { { text = ROUNDED.tl, style = edge } }
  for _, run in ipairs(left) do
    top[#top + 1] = run
  end
  local gap = inner_w - used - right_w
  if gap < 0 then
    -- The right title loses first: the left one names the pane, and a pane that
    -- cannot say what it is is worse than one that cannot say how much changed.
    right, right_w, gap = {}, 0, inner_w - used
  end
  top[#top + 1] = { text = string.rep(ROUNDED.h, math.max(0, gap)), style = edge }
  for _, run in ipairs(right) do
    top[#top + 1] = run
  end
  top[#top + 1] = { text = ROUNDED.tr, style = edge }

  local bar = opts.footer or {}
  local bar_w = 0
  for _, run in ipairs(bar) do
    bar_w = bar_w + widgets.len(run.text)
  end
  local bottom = { { text = ROUNDED.bl, style = edge } }
  if bar_w <= inner_w then
    for _, run in ipairs(bar) do
      bottom[#bottom + 1] = run
    end
    bottom[#bottom + 1] =
      { text = string.rep(ROUNDED.h, math.max(0, inner_w - bar_w)), style = edge }
  else
    bottom[#bottom + 1] = { text = string.rep(ROUNDED.h, inner_w), style = edge }
  end
  bottom[#bottom + 1] = { text = ROUNDED.br, style = edge }

  local rail = { text = ROUNDED.v, style = edge }
  local function column(runs)
    local lines = {}
    for row = 1, inner_h do
      lines[row] = { (runs and runs[row]) or rail }
    end
    return { type = "text", len = 1, text = lines }
  end

  return {
    type = "box",
    axis = "vertical",
    children = {
      top_row_node(top),
      {
        type = "box",
        axis = "horizontal",
        fill = 1,
        children = { column(nil), opts.body, column(opts.right_column) },
      },
      { type = "text", len = 1, text = { bottom } },
    },
  }
end

-- ── bodies for the states that are not a diff ───────────────────────────────

--- A centred stack of lines: what every not-yet-a-diff state looks like.
local function centred(lines)
  local children = { { type = "text", fill = 1, text = "" } }
  for _, line in ipairs(lines) do
    children[#children + 1] = { type = "text", len = 1, align = "center", text = { line } }
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }
  return { type = "box", axis = "vertical", fill = 1, children = children }
end

--- The braille spinner, so "pending" is visibly alive.
---
--- This is the difference the kernel asks for at its publish site and the spec
--- asks for in a scenario: a slow diff must not read as a clean worktree. It is
--- not enough that the words differ — one of these MOVES and the other is a
--- still line of text, which is what the eye actually reads.
local function spinner(elapsed)
  local frames = theme.spinner
  return frames[(math.floor((elapsed or 0) * 10) % #frames) + 1]
end

-- ── the changed-files list: a TREE ──────────────────────────────────────────
--
-- Rows with identity, which is what a tree is for. Each carries `id` and
-- `role = "row"`, so a click reaches `on_click` and a decorator can match them
-- — neither of which the body beside it can offer, and that trade is exactly
-- what D2 accepts.

--- Group the files into directory headers and leaves, preserving each file's
--- index so a click still names the file it drew. v1's `build_file_tree`.
---
--- Sorted BY DIRECTORY, then by name — not by whole path, which is the mistake
--- the first run caught. git emits files in its own order, so a header written
--- on every change of directory printed `src/` twice; sorting by the full path
--- did not fix it, because `src/deep/nested/two.rs` sorts BETWEEN
--- `src/added.txt` and `src/one.lua` and splits `src/` in half again. Grouping
--- means keying on the directory itself.
---
--- The body keeps git's order — this is a navigation aid, not a second copy of
--- the diff — so each leaf carries the path it had there.
---
--- This is also what defines the order `tab` walks. The keys have to agree with
--- what is drawn: a next-file that followed git's order while the list showed
--- directory order would move the highlight somewhere the eye did not expect,
--- and only on repositories where the two differ.
local function file_tree(files)
  local order = {}
  for _, file in ipairs(files) do
    local dir, name = string.match(file.path, "^(.*)/([^/]*)$")
    order[#order + 1] = { file = file, dir = dir or "", name = name or file.path }
  end
  table.sort(order, function(a, b)
    if a.dir ~= b.dir then
      return a.dir < b.dir
    end
    return a.name < b.name
  end)

  local out, previous = {}, nil
  for _, entry in ipairs(order) do
    if entry.dir ~= previous then
      if entry.dir ~= "" then
        out[#out + 1] = { dir = entry.dir }
      end
      previous = entry.dir
    end
    out[#out + 1] = { file = entry.file, depth = entry.dir ~= "" and 1 or 0 }
  end
  return out
end

--- The changed-files list.
---
--- Built from the KERNEL's `files`, not from the incremental parse's. Two
--- reasons, and the first is user-visible: the kernel's list is complete on the
--- frame the diff arrives, so on a large diff the list is whole while the body
--- is still being read — which is the half you navigate by. The second is that
--- `status` and `old_path` are published there now, so nothing has to be
--- recovered from the body to draw a glyph and a rename arrow.
---
--- Both lists come from one `parse_unified_diff` over the same bytes, so index
--- `n` means the same file in each. That is load-bearing: a leaf carries the
--- index the BODY rows use, and a click on a file the parse has not produced
--- rows for yet is deferred rather than dropped (see `wanted`).
--- The paths of the tree's leaves, in the order they are drawn.
local function listed_paths(files)
  local out = {}
  for _, entry in ipairs(file_tree(files)) do
    if entry.file then
      out[#out + 1] = entry.file.path
    end
  end
  return out
end

--- Step the list cursor from `path` by `delta`, in drawn order.
local function step_listed(files, path, delta)
  local order = listed_paths(files)
  if #order == 0 then
    return nil
  end
  local here = nil
  for index, candidate in ipairs(order) do
    if candidate == path then
      here = index
    end
  end
  -- Nowhere yet: the first step lands on an end rather than nothing.
  if not here then
    return delta > 0 and order[1] or order[#order]
  end
  local to = here + delta
  if to < 1 or to > #order then
    return nil
  end
  return order[to]
end

local function files_pane(files, opts)
  local width, height = opts.width, opts.height
  local tree = file_tree(files)
  local here = nil
  for at, entry in ipairs(tree) do
    if entry.file and entry.file.path == opts.current then
      here = at
    end
  end
  local first, last = widgets.window(#tree, height, here or 1)

  local children = {}
  for at = first, last do
    local entry = tree[at]
    if entry.dir then
      children[#children + 1] = {
        type = "text",
        len = 1,
        text = {
          {
            {
              text = rows.pad(widgets.middle_truncate(entry.dir .. "/", width), width),
              style = { fg = theme.muted, bold = true },
            },
          },
        },
      }
    else
      local file = entry.file
      local current = file.path == opts.current
      -- Is this file in the BODY, or only in the list? The kernel lists every
      -- changed file and caps only the patch, so on a large diff there are rows
      -- here with nothing behind them. Unknown until the parse finishes, and
      -- clickable meanwhile — a click is deferred, not dropped.
      local in_body = opts.covered[file.path] == true
      local absent = opts.parsed and not in_body
      local mark = opts.reviewed[file.path] and "✓" or " "
      local counts = " +" .. file.added .. " -" .. file.removed
      local indent = string.rep(" ", entry.depth)
      local name = string.match(file.path, "([^/]*)$") or file.path
      local room = width - widgets.len(indent) - 3 - widgets.len(counts)
      name = widgets.truncate(name, math.max(1, room))
      local head = indent .. mark .. " " .. file.status .. " "
      local text = rows.pad(head .. name .. counts, width)
      local base
      if current then
        base = { fg = theme.role("selection_fg"), bg = theme.role("selection_bg"), bold = true }
      elseif absent then
        -- Muted, because there is nothing to go to. The banner says how many.
        base = { fg = theme.muted }
      else
        base = { fg = theme.text }
      end
      local line
      if current then
        line = { { text = text, style = base } }
      else
        local upto = widgets.len(head)
        line = {
          { text = rows.slice(text, 1, upto - 2), style = base },
          {
            text = rows.slice(text, upto - 1, upto),
            style = { fg = rows.status_fg(file.status) },
          },
          { text = rows.slice(text, upto + 1, upto + widgets.len(name)), style = base },
          {
            text = rows.slice(text, upto + widgets.len(name) + 1, width),
            style = { fg = theme.muted },
          },
        }
      end
      children[#children + 1] = {
        type = "text",
        len = 1,
        -- Identity: what makes this a tree rather than more cells.
        --
        -- By PATH, because the list and the body are two different lists now —
        -- the kernel builds the first from `--numstat`, and this pane builds the
        -- second from the capped body. An index into one means nothing in the
        -- other, and on a capped diff they differ by hundreds of files.
        --
        -- EVERY row that could have a body is a target, including files the
        -- parse has not reached yet. The first version made an unreached row
        -- inert, on the reasoning that there was no row to jump to — true, and
        -- the wrong answer: the list is complete precisely so it can be
        -- navigated while the body is still being read. A click on one is
        -- remembered and honoured the moment the parse reaches it (`wanted`).
        --
        -- A file the finished parse never produced is the one case where the row
        -- really has nowhere to go, and it is drawn muted rather than left to
        -- look clickable.
        id = (not absent) and ("file:" .. file.path) or nil,
        role = (not absent) and "row" or nil,
        text = { line },
      }
    end
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }
  return { type = "box", axis = "vertical", len = width, children = children }
end

-- ── the find bar ────────────────────────────────────────────────────────────

local function find_bar(id, width, hits, at)
  local needle = query(id) or ""
  local place = ""
  if #hits > 0 then
    local ordinal = 0
    for index, row in ipairs(hits) do
      if row <= at then
        ordinal = index
      end
    end
    place = "  " .. ordinal .. "/" .. #hits
  elseif needle ~= "" then
    place = "  no matches"
  end
  local caret = finding(id) and "▏" or ""
  local text = "/" .. needle .. caret .. place
  return {
    type = "text",
    len = 1,
    text = {
      {
        {
          text = rows.pad(text, width),
          style = { fg = theme.text, bg = theme.role("search_bar") },
        },
      },
    },
  }
end

--- What the cap left out, as specifically as it can now be said.
---
--- In FILES first, because that is the question a reviewer scrolling the list is
--- asking, and bytes second. Both halves arrived separately: `raw_bytes` gave the
--- size before the cut, and then the kernel began listing files from `--numstat`
--- independently of the body — so the list is whole while the patch is capped,
--- and the difference between the two counts is exactly what is missing.
---
--- The file count needs a finished parse (it is a count of what the BODY holds),
--- so until then this says bytes alone rather than a number that would keep
--- changing.
local function truncation_notice(entry, parse)
  local shown = 4 * 1024 * 1024
  local whole = entry.raw_bytes
  local size = ""
  if type(whole) == "number" and whole > shown then
    size = string.format(" (4.0 of %.1f MB)", whole / (1024 * 1024))
  end
  local listed = #(entry.files or {})
  if parse.done and listed > #parse.files then
    return string.format(
      "the patch is capped: %d of %d changed files are shown%s",
      #parse.files,
      listed,
      size
    )
  end
  return "the patch is capped — some changes are not shown" .. size
end

-- ── the footer hint strip ───────────────────────────────────────────────────

local function hint(label, keys)
  return {
    { text = " " .. keys, style = { fg = theme.hint } },
    { text = " " .. label, style = { fg = theme.muted } },
  }
end

--- The hint strip along the bottom border.
---
--- Built as a list of whole hints and trimmed a whole hint at a time. Trimming
--- runs instead dropped the label and kept the key, so a 60-column pane advertised
--- a bare `e` — a chord with nothing to say what it does, which is worse than no
--- chord at all.
local function footer(width, ready)
  local hints = {}
  local function put(label, keys)
    hints[#hints + 1] = hint(label, keys)
  end
  if not ready then
    put("refresh", "r")
    put("back", "esc")
  else
    put("move", "j/k")
    put("file", "⇥")
    put("hunk", "[ ]")
    put("find", "/")
    put("fold", "↵")
    -- Every key that changes what the BODY looks like belongs here. `w` was
    -- dropped from this list when `v` was added — replaced rather than added to
    -- — and the result is the failure this pane's own README warns about: the
    -- key still worked, `plugin check` still passed, F1 still listed it, and
    -- there was nothing on screen to say wrapping existed. A capability nobody
    -- can find is not a capability.
    put("wrap", "w")
    put("split", "v")
    put("seen", "m")
    put("refresh", "r")
    put("send", "e")
  end
  local function measure()
    local used = 0
    for _, one in ipairs(hints) do
      for _, run in ipairs(one) do
        used = used + widgets.len(run.text)
      end
    end
    return used
  end
  -- Drop the least important hint — the rightmost — until the strip fits.
  while measure() > width - 2 and #hints > 0 do
    table.remove(hints)
  end
  local out = {}
  for _, one in ipairs(hints) do
    for _, run in ipairs(one) do
      out[#out + 1] = run
    end
  end
  return out
end

-- ── navigation, all of it over LOGICAL rows ─────────────────────────────────

local HUNK_KINDS = { hunk = true, file = true }

--- Move the BODY cursor to `at`, keeping it on a selectable row and in range.
---
--- Clearing the list override here rather than at each call site is deliberate:
--- every way the body moves goes through this function, so "the list follows the
--- body unless you drove it" holds by construction instead of by remembering.
local function move_to(id, in_force, at)
  set_list_at(id, nil)
  local count = #in_force
  if count == 0 then
    return
  end
  at = math.max(1, math.min(at, count))
  -- Step past an unselectable row in the direction of travel, then back the
  -- other way if that ran off the end.
  local from = cursor_of(id)
  local step = at >= from and 1 or -1
  local walk = at
  while walk >= 1 and walk <= count and not diff.selectable(in_force[walk]) do
    walk = walk + step
  end
  if walk < 1 or walk > count then
    walk = at
    while walk >= 1 and walk <= count and not diff.selectable(in_force[walk]) do
      walk = walk - step
    end
  end
  if walk >= 1 and walk <= count then
    set_cursor(id, walk)
  end
end

--- A file the user asked for that the parse has not produced rows for yet.
---
--- Module-local rather than in `state` for the reason the parse cache is: this
--- is a fact about a parse in progress, not about the review, and it is
--- meaningless once the parse finishes. Keyed per session because everything
--- else here is.
local wanted = {}

--- Honour a deferred jump once its file has rows.
---
--- Called from `render`, which is where the parse advances — so the frame that
--- reaches the file is the frame that lands on it. Writing `state` from a render
--- is unusual and deliberate: the alternative is a click that does nothing until
--- the user presses another key, which is a click that looks broken.
--- Idempotent, so a second render in the same frame changes nothing.
local function settle_jump(id, parse, in_force, move)
  local path = wanted[id]
  if not path then
    return
  end
  local row = diff.file_row(in_force, path)
  if row then
    wanted[id] = nil
    move(row)
  elseif parse.done then
    -- The parse finished without ever producing that file: its patch was past
    -- the cut. Forget it rather than waiting forever — the row is drawn muted
    -- from here on, so the answer is on screen rather than only in this table.
    wanted[id] = nil
  end
end

--- What the body's visual lines mapped to, from the frame just drawn.
---
--- A surface carries no per-line identity — that is the trade D2 accepts — so a
--- click on it arrives as a coordinate, and turning a coordinate back into a
--- logical row is the plugin's job. It can do it because it OWNS the geometry:
--- it decided which rows went where, and this is that decision written down.
---
--- Which is the answer to whether a dense pane needs a fifth node kind for
--- clickable body lines. It does not: `surface` takes an `id` like any node, the
--- paint walk records the rect, and `on_click` hands back `x`/`y` inside it.
local last_body_map = {}

--- The pane's own height for the body, which `on_action` needs and only
--- `render` knows. Recorded from the last frame rather than recomputed, which is
--- the documented way round: a value derived while drawing is invisible to a key
--- unless the drawing wrote it down.
local last_body_height = {}

local function page(id, in_force, direction)
  local height = last_body_height[id] or PAGE
  move_to(id, in_force, cursor_of(id) + direction * math.max(1, height - 1))
end

-- ── the plugin ──────────────────────────────────────────────────────────────

return {
  name = NAME,
  slot = SLOT,
  -- The centre is a switch: the agent pane occupies it and this is its
  -- alternate, brought forward by being focused. Hence the pill below — an
  -- alternate nobody advertises is a pane that loads, places, passes every
  -- check, and never appears.
  slot_mode = "switch",
  order = 30,
  focusable = true,

  pills = { { action = "review.open", label = "Review", priority = 20 } },

  settings = {
    { id = "side", desc = "Start with the diff side by side rather than unified", default = false },
    { id = "syntax", desc = "Colour the code, not only the change", default = true },
    { id = "wrap", desc = "Start with long diff lines soft-wrapped", default = false },
    { id = "files", desc = "Show the changed-files list beside the diff", default = true },
  },

  keys = {
    -- v1's chord and its F-key alternate. `passthrough` leaves a bare
    -- Ctrl+<letter> to the agent's own line editing while a terminal has focus,
    -- which is why the F-key exists: it is the one that works from where the
    -- user is standing.
    {
      key = "ctrl+x",
      action = "review.open",
      desc = "review this session's changes",
      scope = "global",
      group = "UI",
      passthrough = true,
    },
    {
      key = "f7",
      action = "review.open",
      desc = "review this session's changes",
      scope = "global",
      group = "UI",
    },

    { key = "j", action = "review.next", desc = "next line" },
    { key = "down", action = "review.next", desc = "next line" },
    { key = "k", action = "review.previous", desc = "previous line" },
    { key = "up", action = "review.previous", desc = "previous line" },
    { key = "pagedown", action = "review.page_down", desc = "page down" },
    { key = "pageup", action = "review.page_up", desc = "page up" },
    { key = "g", action = "review.top", desc = "first line" },
    { key = "G", action = "review.bottom", desc = "last line" },
    { key = "tab", action = "review.next_file", desc = "next file" },
    { key = "shift+tab", action = "review.previous_file", desc = "previous file" },
    { key = "]", action = "review.next_hunk", desc = "next hunk" },
    { key = "[", action = "review.previous_hunk", desc = "previous hunk" },
    { key = "l", action = "review.right", desc = "scroll right" },
    { key = "right", action = "review.right", desc = "scroll right" },
    { key = "h", action = "review.left", desc = "scroll left" },
    { key = "left", action = "review.left", desc = "scroll left" },
    { key = "v", action = "review.side", desc = "side-by-side, or unified" },
    { key = "w", action = "review.wrap", desc = "soft-wrap long lines" },
    { key = "f", action = "review.files", desc = "show the changed-files list" },
    { key = "/", action = "review.find", desc = "find in the diff" },
    -- One key, two meanings, and they never overlap: while the query has the
    -- keyboard `enter` commits it, and otherwise it folds the file you are on.
    -- v1 spells the second `cr_toggle_fold` and reaches it from `enter` too.
    {
      key = "enter",
      action = "review.find_commit",
      desc = "keep the search, or fold this file",
    },
    { key = "n", action = "review.find_next", desc = "next match" },
    { key = "N", action = "review.find_previous", desc = "previous match" },
    { key = "m", action = "review.mark", desc = "mark this file seen" },
    -- `r` is refresh, not mark, because `r` is refresh in every other pane and a
    -- chord that means two things depending on where you are standing is worse
    -- than one that is spelled differently here.
    { key = "r", action = "review.refresh", desc = "recompute the diff" },
    { key = "e", action = "review.send", desc = "send this review to the agent" },
    { key = "esc", action = "review.close", desc = "close the search, or go back" },
    -- Declared, and honest about being unbuilt: a key in `F1` that says what is
    -- missing is more use than a key that is absent for a reason nobody can see.
    { key = "c", action = "review.comment", desc = "comment (needs a kernel change)" },
    { key = "s", action = "review.summary", desc = "summarise (needs a kernel change)" },
  },

  render = function(ctx)
    local width, height = ctx.width or 0, ctx.height or 0
    local edge = border_style(ctx.focused)
    local session = selected()
    local title_style = ctx.focused
        and { fg = theme.role("inverted_fg"), bg = theme.accent, bold = true }
      or { fg = theme.accent }

    local function frame(opts)
      -- The chevron first, then the title: v1 puts the collapse toggle at the
      -- very left of the central pane's top border, before anything that names
      -- the view.
      --
      -- Separated by a BORDER cell rather than a space. That is the grammar the
      -- agent pane sets and the reason it gives: a gap drawn in the border's own
      -- colour makes the two read as sitting ON the border, where two spaces
      -- read as one run of padding and the chevron stops looking like a button.
      local left = collapse_runs(width)
      if #left > 0 then
        left[#left + 1] = { text = ROUNDED.h, style = edge }
      end
      left[#left + 1] = { text = " Code review ", style = title_style }
      return chrome({
        width = width,
        height = height,
        border = edge,
        left = left,
        right = opts.right,
        right_column = opts.right_column,
        footer = footer(width, opts.ready == true),
        body = opts.body,
      })
    end

    if not session then
      return frame({
        body = centred({
          { { text = "No session selected", style = { fg = theme.secondary } } },
          { { text = "pick one in the session list", style = { fg = theme.muted } } },
        }),
      })
    end

    local id = session.id
    local entry = published(session)
    local range = export.range(session)
    local range_runs = {
      { text = " ", style = edge },
      { text = range, style = { fg = theme.branch } },
      { text = " ", style = edge },
    }

    -- State one: nobody has asked. Since the kernel began driving the request
    -- from the selection this is a frame or two at most, so it is drawn as the
    -- transient it now is rather than as a resting state with advice in it.
    if not entry then
      return frame({
        right = range_runs,
        body = centred({
          {
            {
              text = spinner(ctx.elapsed) .. " Asking for the diff…",
              style = { fg = theme.muted },
            },
          },
        }),
      })
    end

    local epoch = epoch_of(id, entry.state)

    -- State two: asked, not finished. Distinct from "no changes" by motion, not
    -- only by wording — the property the kernel comments at its publish site.
    if entry.state == "pending" then
      return frame({
        right = range_runs,
        body = centred({
          { { text = spinner(ctx.elapsed) .. " Building diff…", style = { fg = theme.accent } } },
          { { text = range, style = { fg = theme.branch } } },
        }),
      })
    end

    -- State three: it failed, and says why in the kernel's own words.
    if entry.state == "failed" then
      return frame({
        right = range_runs,
        body = centred({
          { { text = "could not build the diff", style = { fg = theme.bad, bold = true } } },
          { { text = entry.error or "no reason given", style = { fg = theme.muted } } },
          { { text = "press r to try again", style = { fg = theme.hint } } },
        }),
      })
    end

    local parse = diff.parse(id, entry.body or {}, epoch)
    -- The rows on screen. Two flat lists over one parse — unified, or paired for
    -- the side-by-side layout — and which one is in force decides what a
    -- selectable unit IS, so everything downstream takes this and not
    -- `parse.rows`.
    local in_force = rows_in_force(parse, id)
    settle_jump(id, parse, in_force, function(row)
      move_to(id, in_force, row)
    end)
    local reviewed = marks_of(id)

    -- State four: ready, and empty. A static line naming the range it looked at,
    -- so it can never be mistaken for the animated one above.
    --
    -- Asked of the KERNEL's file list rather than the parse's, so it is answered
    -- on the frame the diff arrives. Waiting for the parse would have shown "No
    -- changes" for a moment on a diff that has plenty.
    if #(entry.files or {}) == 0 then
      return frame({
        right = range_runs,
        body = centred({
          { { text = "No changes", style = { fg = theme.secondary, bold = true } } },
          { { text = range, style = { fg = theme.branch } } },
          {
            {
              text = session.base_branch and "this worktree matches its base branch"
                or "nothing uncommitted in this worktree",
              style = { fg = theme.muted },
            },
          },
        }),
      })
    end

    -- State five: a diff. Everything below is the pane proper.
    --
    -- Totalled from the kernel's list too: summing the parse's would have the
    -- header counting up while the body was read, which reads as the diff
    -- growing rather than as the pane catching up.
    local added, removed = 0, 0
    for _, file in ipairs(entry.files or {}) do
      added = added + file.added
      removed = removed + file.removed
    end

    local inner_w, inner_h = math.max(1, width - 2), math.max(1, height - 2)
    local hits = matches(id, parse, in_force, query(id))
    local bar = find_open(id) and 1 or 0
    local notice = entry.truncated and 1 or 0
    local body_h = math.max(1, inner_h - bar - notice)
    last_body_height[id] = body_h

    local at = math.min(cursor_of(id), math.max(1, #in_force))
    local covered = diff.covered(parse)
    -- Which files are collapsed, as a set, for the header chevrons.
    local overrides = folds_of(id)
    local fold_state = {}
    for _, file in ipairs(entry.files or {}) do
      if folded(reviewed, overrides, file.path) then
        fold_state[file.path] = true
      end
    end
    -- The list points wherever it was driven, and otherwise at whatever the body
    -- is showing.
    local current_path = list_at(id) or diff.path_of(parse, in_force, at)

    local published_files = entry.files or {}
    local show_files = files_shown() and inner_w >= FILES_MIN_PANE and #published_files > 0
    local files_w = 0
    if show_files then
      files_w = math.max(FILES_WIDTH_MIN, math.min(FILES_WIDTH_MAX, math.floor(inner_w * 0.3)))
    end
    local body_w = math.max(1, inner_w - (show_files and (files_w + 1) or 0))

    -- Side by side neither wraps nor scrolls horizontally: a wrapped half would
    -- have to push the other half's rows down to stay level, and the alignment
    -- IS the layout. v1 pins both for the same reason.
    local wrap = wrapping() and not side_by_side()
    local digits = rows.gutter_digits(parse)
    local window = {
      width = body_w,
      height = body_h,
      digits = digits,
      wrap = wrap,
      hscroll = (wrap or side_by_side()) and 0 or hscroll_of(id),
      query = query(id) and string.lower(query(id)) or nil,
      reviewed = reviewed,
      folded = fold_state,
      canonical = parse.rows,
      -- A row's language, by the file it belongs to. A function rather than a
      -- table because the window only ever asks about the rows it draws — a
      -- 400-file diff would otherwise build 400 entries a frame to use forty.
      lang_of = highlighting() and function(row)
        return syntax.lang_of(parse, row.file)
      end or nil,
      selected = at,
    }
    local top = rows.scroll_to(in_force, math.min(top_of(id), at), window)
    local lines, logical, used = rows.window(in_force, top, window)
    last_body_map[id] = logical
    if used ~= top_of(id) then
      set_top(id, used)
    end

    -- The diff body: a SURFACE. Its own `scroll` stays 0 — the window above is
    -- logical, and the surface's offset counts visual lines, so letting it
    -- scroll too would be two anchors fighting over one body.
    -- `id` on a surface is what makes the body clickable. Nothing else is
    -- needed: the kernel records the rect of any node carrying identity, and a
    -- click comes back with coordinates inside it.
    local body = { type = "surface", id = "body", cells = lines, fill = 1 }

    local content = { body }
    if show_files then
      table.insert(content, 1, {
        type = "text",
        len = 1,
        text = (function()
          local column = {}
          for row = 1, body_h do
            column[row] = { { text = ROUNDED.v, style = edge } }
          end
          return column
        end)(),
      })
      table.insert(
        content,
        1,
        files_pane(entry.files or {}, {
          width = files_w,
          height = body_h,
          current = current_path,
          covered = covered,
          parsed = parse.done,
          reviewed = reviewed,
        })
      )
    end

    local stack = {}
    if notice == 1 then
      stack[#stack + 1] = {
        type = "text",
        len = 1,
        text = {
          {
            {
              text = rows.pad(" " .. truncation_notice(entry, parse) .. " ", inner_w),
              style = { fg = theme.role("inverted_fg"), bg = theme.bad, bold = true },
            },
          },
        },
      }
    end
    if bar == 1 then
      stack[#stack + 1] = find_bar(id, inner_w, hits, at)
    end
    stack[#stack + 1] = { type = "box", axis = "horizontal", fill = 1, children = content }

    -- The parse is still running: say so on the border rather than in the body,
    -- which is already showing the part that is readable.
    --
    -- The percentage is also what KEEPS the parse running. An idle interface
    -- paints at `FORCE_REDRAW_INTERVAL` — four frames a second — and the parse
    -- only advances when this function is called. A progress figure that changes
    -- every frame makes the tree differ, which is what holds `dirty` set and
    -- brings the loop back to its 60fps floor until the parse is done. Drawing
    -- the progress is not decoration here; it is the thing that converges.
    local right = range_runs
    if not parse.done then
      right = {
        { text = " ", style = edge },
        {
          text = "reading " .. math.floor(diff.progress(parse) * 100) .. "%",
          style = { fg = theme.warn },
        },
        { text = " ", style = edge },
      }
    else
      right = {
        { text = " ", style = edge },
        { text = range, style = { fg = theme.branch } },
        { text = "  +" .. added, style = { fg = theme.role("diff_added") } },
        { text = " -" .. removed, style = { fg = theme.role("diff_removed") } },
        { text = " ", style = edge },
      }
    end

    return frame({
      ready = true,
      right = right,
      -- `inner_h`, not the pane height: the column is painted into the inner
      -- rows, so a bar built for two rows more put its ▼ past the last one and
      -- lost it. Caught in a capture, not in a check.
      right_column = scrollbar(inner_h, #in_force, at - 1),
      body = { type = "box", axis = "vertical", fill = 1, children = stack },
    })
  end,

  --- Raw keys, for the find query only.
  ---
  --- Reached only after the registry has offered the chord as an action, so
  --- every letter handled here is one `on_action` deliberately declined while
  --- the query has the keyboard.
  on_key = function(key)
    local id = current_id()
    if not id or not finding(id) then
      return false
    end
    if key.key == "backspace" then
      set_query(id, string.sub(query(id) or "", 1, -2))
      return true
    end
    if key.char and not key.ctrl and not key.alt and widgets.len(key.char) == 1 then
      set_query(id, (query(id) or "") .. key.char)
      return true
    end
    return false
  end,

  on_click = function(hit)
    if hit.id == "body" then
      -- A coordinate, resolved through the map the last frame recorded. The
      -- surface has no per-line identity to hand back, and does not need one.
      local session = selected()
      local map = session and last_body_map[session.id]
      local row = map and map[(hit.y or 0) + 1]
      if not row then
        return false
      end
      local entry = published(session)
      if not entry or entry.state ~= "ready" then
        return false
      end
      local parse = diff.parse(session.id, entry.body or {}, epochs[session.id] or 0)
      move_to(session.id, rows_in_force(parse, session.id), row)
      return true
    end

    local path = hit.id and string.match(hit.id, "^file:(.+)$")
    if not path then
      return false
    end
    local session = selected()
    if not session then
      return false
    end
    local entry = published(session)
    if not entry or entry.state ~= "ready" then
      return false
    end
    local parse = diff.parse(session.id, entry.body or {}, epochs[session.id] or 0)
    local in_force = rows_in_force(parse, session.id)
    local row = diff.file_row(in_force, path)
    if row then
      move_to(session.id, in_force, row)
    else
      -- The list is the kernel's and is complete; the body is this pane's and is
      -- not, yet. Remember the ask and let the parse deliver it.
      wanted[session.id] = path
    end
    return true
  end,

  on_action = function(action)
    if action == "review.open" then
      -- One key in, the same key out — and OUT is the pane that shares this
      -- slot, not wherever focus happened to be. See `slot_mate`.
      --
      -- `thurbox.focus` is the snapshot's answer to "which pane holds focus",
      -- republished every frame and readable anywhere. Distinct from
      -- `ctx.focused`, which is a render value and gone by the time a key
      -- arrives: this is a READ, and reads are what a handler has.
      if ((thurbox and thurbox.focus) or "") == NAME then
        leave()
      else
        command("focus", { text = NAME })
      end
      return true
    end

    local session = selected()
    if not session then
      return action ~= "review.close"
    end
    local id = session.id

    -- THE FIND QUERY OWNS THE KEYBOARD while it is being typed, and this gate is
    -- first for a reason found by running it: with the gate further down, typing
    -- `greet` reached `review.refresh` on the `r` and the query came out `geet`.
    -- Every letter this pane binds is a letter somebody will type into a search
    -- box, so the only safe order is to decline them all before any of them is
    -- looked at. Returning false is what lets `on_key` below see the character.
    if finding(id) then
      if action == "review.close" then
        close_find(id)
        return true
      end
      if action == "review.find_commit" then
        -- v1's Tab: stop capturing, keep the bar for its highlighting, and leave
        -- `n`/`N` stepping from where the cursor is.
        state["typing:" .. id] = nil
        return true
      end
      return false
    end

    -- Everything below this line needs the diff. The three that do not are
    -- handled first so they still work while one is being built.
    if action == "review.close" then
      if find_open(id) then
        close_find(id)
        return true
      end
      -- The same destination as the key that opened it. Closing a review means
      -- the centre showing its main pane again — v1's behaviour, and what the
      -- open key now does; an `Esc` that went somewhere else would make the two
      -- ways out of this pane disagree.
      leave()
      return true
    end
    if action == "review.refresh" then
      -- Drops the kernel's cached answer; the loop re-requests on the next
      -- frame and the worker recomputes. Ours goes too, so a recomputed diff of
      -- exactly the same shape is still re-read.
      command("diff", { session = id })
      diff.forget(id)
      match_cache[id] = nil
      return true
    end
    if action == "review.comment" or action == "review.summary" then
      -- Deliberately does nothing but say so. `review_comments` exists in the
      -- kernel's database and is not published to Lua, and there is no command
      -- to write one — so a comment kept here would look saved and would not be.
      command("focus", { text = NAME })
      return true
    end

    local entry = published(session)
    if not entry or entry.state ~= "ready" then
      return true
    end
    local parse = diff.parse(id, entry.body or {}, epochs[id] or 0)
    local in_force = rows_in_force(parse, id)
    local at = math.min(cursor_of(id), math.max(1, #in_force))

    if action == "review.next" then
      move_to(id, in_force, at + 1)
    elseif action == "review.previous" then
      move_to(id, in_force, at - 1)
    elseif action == "review.page_down" then
      page(id, in_force, 1)
    elseif action == "review.page_up" then
      page(id, in_force, -1)
    elseif action == "review.top" then
      move_to(id, in_force, 1)
      set_top(id, 1)
    elseif action == "review.bottom" then
      move_to(id, in_force, #in_force)
    elseif action == "review.next_file" or action == "review.previous_file" then
      -- Walks the LIST, not the body's file rows. Before `962aef7` those were
      -- the same set; now the list is complete and the body is capped, so
      -- walking the body's rows could reach 77 of 400 files and the other 323
      -- were named on screen and unreachable by any key.
      --
      -- Where the body can follow, it does, and the two stay in step. Where it
      -- cannot — a file whose patch was cut — only the list moves, and the row
      -- it lands on is the muted kind that says why.
      local delta = action == "review.next_file" and 1 or -1
      local from = list_at(id) or diff.path_of(parse, in_force, at)
      local to = step_listed(entry.files or {}, from, delta)
      if to then
        local row = diff.file_row(in_force, to)
        if row then
          move_to(id, in_force, row)
        else
          set_list_at(id, to)
        end
      end
    elseif action == "review.next_hunk" then
      local to = diff.jump(in_force, at, HUNK_KINDS, 1)
      if to then
        move_to(id, in_force, to)
      end
    elseif action == "review.previous_hunk" then
      local to = diff.jump(in_force, at, HUNK_KINDS, -1)
      if to then
        move_to(id, in_force, to)
      end
    elseif action == "review.right" then
      set_hscroll(id, hscroll_of(id) + HSCROLL_STEP)
    elseif action == "review.left" then
      set_hscroll(id, math.max(0, hscroll_of(id) - HSCROLL_STEP))
    elseif action == "review.side" then
      -- The cursor is an index into the list in force, and the two lists are
      -- different lengths — a hunk of twenty deletions is twenty rows unified
      -- and twenty paired rows only if twenty additions matched it. Left alone,
      -- `v` would move you to a different file. Remapped through the diff line
      -- the cursor was on, so the layout changes under you and your place does
      -- not.
      local was = in_force
      -- Computed from what the setting is ABOUT to be, not from a re-read: the
      -- command lands a frame later, so reading it back here would remap
      -- through the layout that is still on screen.
      local going = set_toggle("side", false)
      local now = going and diff.paired(parse) or parse.rows
      set_cursor(id, diff.remap(parse, was, at, now))
      set_top(id, 1)
      -- Neither offset survives the change: side-by-side pins both, and coming
      -- back from it with a stale horizontal scroll would look like the pane had
      -- lost the left edge.
      set_hscroll(id, 0)
    elseif action == "review.wrap" then
      set_toggle("wrap", false)
      -- Wrapping shows every column, so an offset into the text would only
      -- confuse the next unwrapped frame.
      set_hscroll(id, 0)
    elseif action == "review.files" then
      set_toggle("files", true)
    elseif action == "review.find" then
      -- Re-opening keeps the query: `/` after a committed search puts the cursor
      -- back in it rather than making you type it again.
      state["find:" .. id], state["typing:" .. id] = true, true
    elseif action == "review.find_commit" then
      -- Not searching, so this is the fold. The cursor is put on the file's
      -- header first: it is the one row a fold keeps, so the cursor cannot be
      -- left pointing into rows that are about to disappear.
      local path = list_at(id) or diff.path_of(parse, in_force, at)
      if not path then
        return true
      end
      local header = diff.file_row(in_force, path)
      if header then
        move_to(id, in_force, header)
      end
      toggle_fold(id, path)
      set_top(id, 1)
    elseif action == "review.find_next" or action == "review.find_previous" then
      local hits = matches(id, parse, in_force, query(id))
      if #hits == 0 then
        return true
      end
      local forward = action == "review.find_next"
      local to = nil
      if forward then
        for _, row in ipairs(hits) do
          if row > at then
            to = row
            break
          end
        end
        to = to or hits[1]
      else
        for index = #hits, 1, -1 do
          if hits[index] < at then
            to = hits[index]
            break
          end
        end
        to = to or hits[#hits]
      end
      move_to(id, in_force, to)
    elseif action == "review.mark" then
      -- The LIST's file, so a file whose patch was cut can still be marked seen.
      -- Reading a file you cannot open here — in an editor, on a forge — and
      -- ticking it off is a real thing to want, and it is the only thing the
      -- pane can offer for those files.
      local path = list_at(id) or diff.path_of(parse, in_force, at)
      if path then
        toggle_mark(id, path)
      end
    elseif action == "review.send" then
      command("send", {
        session = id,
        text = "Please address the following code review:\n\n"
          -- Exported from the CANONICAL rows whichever layout is on screen: a
          -- quoted hunk is a diff, and a diff is unified. Which columns the
          -- reviewer happened to be looking at is not the agent's business.
          .. export.markdown(
            session,
            parse,
            diff.remap(parse, in_force, at, parse.rows),
            marks_of(id)
          ),
      })
      -- Out to the pane that shares this slot, to watch the agent read it —
      -- the same way out as `esc` and the open key.
      leave()
    else
      return false
    end
    return true
  end,
}
