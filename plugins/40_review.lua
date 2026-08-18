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

local theme = require("lib.theme")
local widgets = require("lib.widgets")

local diff = require("thurbox-code-review.lib.diff")
local rows = require("thurbox-code-review.lib.rows")
local export = require("thurbox-code-review.lib.export")

--- What this pane is called: the focus ring, `command("focus", …)`, and the
--- name a settings lookup filters on.
local NAME = "review"

--- The pane the `esc` key hands focus back to. Named rather than derived
--- because "where you came from" is not a thing a plugin can read, and the
--- centre slot's other occupant is what the user was looking at.
local BACK_TO = "agent"

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

-- ── the two toggles ─────────────────────────────────────────────────────────
--
-- Declared as settings so they get a row in the settings modal, and overridden
-- in `state` by their key: the setting is what the pane STARTS as, the key is
-- what you did to it since.

local function toggle_value(id, declared)
  local held = state[id]
  if held ~= nil then
    return held == true
  end
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

local function wrapping()
  return toggle_value("wrap", false)
end

local function files_shown()
  return toggle_value("files", true)
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

local function matches(id, parse, needle)
  if not needle then
    return {}
  end
  local held = match_cache[id]
  if not (held and held.needle == needle and held.epoch == epochs[id]) then
    held = { needle = needle, epoch = epochs[id], scanned = 0, list = {} }
    match_cache[id] = held
  end
  local lowered = string.lower(needle)
  local list = held.list
  for at = held.scanned + 1, #parse.rows do
    if string.find(string.lower(rows.text_of(parse.rows[at])), lowered, 1, true) then
      list[#list + 1] = at
    end
  end
  held.scanned = #parse.rows
  return list
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
      { type = "text", len = 1, text = { top } },
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
--- the diff — so each leaf carries the index it had there.
local function file_tree(files)
  local order = {}
  for index, file in ipairs(files) do
    local dir, name = string.match(file.path, "^(.*)/([^/]*)$")
    order[#order + 1] = { index = index, file = file, dir = dir or "", name = name or file.path }
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
    out[#out + 1] = { index = entry.index, file = entry.file, depth = entry.dir ~= "" and 1 or 0 }
  end
  return out
end

local function files_pane(parse, opts)
  local width, height = opts.width, opts.height
  local tree = file_tree(parse.files)
  local here = nil
  for at, entry in ipairs(tree) do
    if entry.index == opts.current then
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
      local current = entry.index == opts.current
      local mark = opts.reviewed[file.path] and "✓" or " "
      local counts = " +" .. file.added .. " -" .. file.removed
      local indent = string.rep(" ", entry.depth)
      local name = string.match(file.path, "([^/]*)$") or file.path
      local room = width - widgets.len(indent) - 3 - widgets.len(counts)
      name = widgets.truncate(name, math.max(1, room))
      local head = indent .. mark .. " " .. file.status .. " "
      local text = rows.pad(head .. name .. counts, width)
      local base = current
          and { fg = theme.role("selection_fg"), bg = theme.role("selection_bg"), bold = true }
        or { fg = theme.text }
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
        id = "file:" .. entry.index,
        role = "row",
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
    put("wrap", "w")
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

local FILE_KINDS = { file = true }
local HUNK_KINDS = { hunk = true, file = true }

--- Move the cursor to `at`, keeping it on a selectable row and in range.
local function move_to(id, parse, at)
  local count = #parse.rows
  if count == 0 then
    return
  end
  at = math.max(1, math.min(at, count))
  -- Step past an unselectable row in the direction of travel, then back the
  -- other way if that ran off the end.
  local from = cursor_of(id)
  local step = at >= from and 1 or -1
  local walk = at
  while walk >= 1 and walk <= count and not diff.selectable(parse.rows[walk]) do
    walk = walk + step
  end
  if walk < 1 or walk > count then
    walk = at
    while walk >= 1 and walk <= count and not diff.selectable(parse.rows[walk]) do
      walk = walk - step
    end
  end
  if walk >= 1 and walk <= count then
    set_cursor(id, walk)
  end
end

--- The pane's own height for the body, which `on_action` needs and only
--- `render` knows. Recorded from the last frame rather than recomputed, which is
--- the documented way round: a value derived while drawing is invisible to a key
--- unless the drawing wrote it down.
local last_body_height = {}

local function page(id, parse, direction)
  local height = last_body_height[id] or PAGE
  move_to(id, parse, cursor_of(id) + direction * math.max(1, height - 1))
end

-- ── the plugin ──────────────────────────────────────────────────────────────

return {
  name = NAME,
  slot = "center",
  -- The centre is a switch: the agent pane occupies it and this is its
  -- alternate, brought forward by being focused. Hence the pill below — an
  -- alternate nobody advertises is a pane that loads, places, passes every
  -- check, and never appears.
  slot_mode = "switch",
  order = 30,
  focusable = true,

  pills = { { action = "review.open", label = "Review", priority = 20 } },

  settings = {
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
    { key = "w", action = "review.wrap", desc = "soft-wrap long lines" },
    { key = "f", action = "review.files", desc = "show the changed-files list" },
    { key = "/", action = "review.find", desc = "find in the diff" },
    { key = "enter", action = "review.find_commit", desc = "keep the search, stop typing" },
    { key = "n", action = "review.find_next", desc = "next match" },
    { key = "N", action = "review.find_previous", desc = "previous match" },
    { key = "m", action = "review.mark", desc = "mark this file seen" },
    -- `r` is refresh, not mark, because `r` is refresh in every other pane and a
    -- chord that means two things depending on where you are standing is worse
    -- than one that is spelled differently here.
    { key = "r", action = "review.refresh", desc = "recompute the diff" },
    { key = "e", action = "review.send", desc = "send this review to the agent" },
    { key = "esc", action = "review.close", desc = "back to the agent" },
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
      return chrome({
        width = width,
        height = height,
        border = edge,
        left = { { text = " Code review ", style = title_style } },
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
    local reviewed = marks_of(id)

    -- State four: ready, and empty. A static line naming the range it looked at,
    -- so it can never be mistaken for the animated one above.
    if #parse.files == 0 and parse.done then
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
    local added, removed = 0, 0
    for _, file in ipairs(parse.files) do
      added = added + file.added
      removed = removed + file.removed
    end

    local inner_w, inner_h = math.max(1, width - 2), math.max(1, height - 2)
    local hits = matches(id, parse, query(id))
    local bar = find_open(id) and 1 or 0
    local notice = entry.truncated and 1 or 0
    local body_h = math.max(1, inner_h - bar - notice)
    last_body_height[id] = body_h

    local at = math.min(cursor_of(id), math.max(1, #parse.rows))
    local current_file = diff.file_of(parse.rows, at)

    local show_files = files_shown() and inner_w >= FILES_MIN_PANE and #parse.files > 0
    local files_w = 0
    if show_files then
      files_w = math.max(FILES_WIDTH_MIN, math.min(FILES_WIDTH_MAX, math.floor(inner_w * 0.3)))
    end
    local body_w = math.max(1, inner_w - (show_files and (files_w + 1) or 0))

    local wrap = wrapping()
    local digits = rows.gutter_digits(parse)
    local window = {
      width = body_w,
      height = body_h,
      digits = digits,
      wrap = wrap,
      hscroll = wrap and 0 or hscroll_of(id),
      query = query(id) and string.lower(query(id)) or nil,
      reviewed = reviewed,
      selected = at,
    }
    local top = rows.scroll_to(parse.rows, math.min(top_of(id), at), window)
    local lines, _, used = rows.window(parse.rows, top, window)
    if used ~= top_of(id) then
      set_top(id, used)
    end

    -- The diff body: a SURFACE. Its own `scroll` stays 0 — the window above is
    -- logical, and the surface's offset counts visual lines, so letting it
    -- scroll too would be two anchors fighting over one body.
    local body = { type = "surface", cells = lines, fill = 1 }

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
        files_pane(parse, {
          width = files_w,
          height = body_h,
          current = current_file,
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
              text = rows.pad(" diff truncated at 4 MiB — some changes are not shown ", inner_w),
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
      right_column = scrollbar(inner_h, #parse.rows, at - 1),
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
    local index = hit.id and string.match(hit.id, "^file:([0-9]+)$")
    if not index then
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
    local row = diff.file_row(parse.rows, tonumber(index))
    if row then
      move_to(session.id, parse, row)
    end
    return true
  end,

  on_action = function(action)
    if action == "review.open" then
      command("focus", { text = NAME })
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
      command("focus", { text = BACK_TO })
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
    local at = math.min(cursor_of(id), math.max(1, #parse.rows))

    if action == "review.next" then
      move_to(id, parse, at + 1)
    elseif action == "review.previous" then
      move_to(id, parse, at - 1)
    elseif action == "review.page_down" then
      page(id, parse, 1)
    elseif action == "review.page_up" then
      page(id, parse, -1)
    elseif action == "review.top" then
      move_to(id, parse, 1)
      set_top(id, 1)
    elseif action == "review.bottom" then
      move_to(id, parse, #parse.rows)
    elseif action == "review.next_file" then
      local to = diff.jump(parse.rows, at, FILE_KINDS, 1)
      if to then
        move_to(id, parse, to)
      end
    elseif action == "review.previous_file" then
      local to = diff.jump(parse.rows, at, FILE_KINDS, -1)
      if to then
        move_to(id, parse, to)
      end
    elseif action == "review.next_hunk" then
      local to = diff.jump(parse.rows, at, HUNK_KINDS, 1)
      if to then
        move_to(id, parse, to)
      end
    elseif action == "review.previous_hunk" then
      local to = diff.jump(parse.rows, at, HUNK_KINDS, -1)
      if to then
        move_to(id, parse, to)
      end
    elseif action == "review.right" then
      set_hscroll(id, hscroll_of(id) + HSCROLL_STEP)
    elseif action == "review.left" then
      set_hscroll(id, math.max(0, hscroll_of(id) - HSCROLL_STEP))
    elseif action == "review.wrap" then
      state.wrap = not wrapping()
      -- Wrapping shows every column, so an offset into the text would only
      -- confuse the next unwrapped frame.
      set_hscroll(id, 0)
    elseif action == "review.files" then
      state.files = not files_shown()
    elseif action == "review.find" then
      -- Re-opening keeps the query: `/` after a committed search puts the cursor
      -- back in it rather than making you type it again.
      state["find:" .. id], state["typing:" .. id] = true, true
    elseif action == "review.find_commit" then
      return false
    elseif action == "review.find_next" or action == "review.find_previous" then
      local hits = matches(id, parse, query(id))
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
      move_to(id, parse, to)
    elseif action == "review.mark" then
      local index = diff.file_of(parse.rows, at)
      local file = index and parse.files[index]
      if file then
        toggle_mark(id, file.path)
      end
    elseif action == "review.send" then
      command("send", {
        session = id,
        text = "Please address the following code review:\n\n"
          .. export.markdown(session, parse, at, marks_of(id)),
      })
      command("focus", { text = BACK_TO })
    else
      return false
    end
    return true
  end,
}
