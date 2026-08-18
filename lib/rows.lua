-- Logical rows -> the VISUAL lines a `surface` is painted from.
--
-- `diff.lua` produces one logical row per diff line. This file turns a window of
-- those into cells. It is the only place in the pane that knows a logical row
-- can occupy more than one screen line, and keeping that knowledge in one file
-- is what keeps the rule in `diff.lua` true:
--
--   wrapping expands VISUAL rows only; selection and anchoring stay LOGICAL.
--
-- Every visual line built here is returned alongside the logical index it came
-- from, so a click, the scrollbar and the cursor all still speak in logical
-- rows however the text was folded to fit.
--
-- v1 does the same thing in `ui::code_review::render_rows`, and its comment is
-- worth carrying over: *only the vertical windowing becomes visual.*

local theme = require("lib.theme")
local widgets = require("lib.widgets")

local syntax = require("thurbox-code-review.lib.syntax")

local M = {}

-- ── utf8-safe slicing ───────────────────────────────────────────────────────
--
-- `#` counts bytes. Every column computed from it is wrong the moment a diff
-- touches a line with an accent, an arrow or a box-drawing character in it —
-- which, in this repository, is most of them.

local function len(text)
  return widgets.len(text)
end

--- Byte offset just past character `n`.
local function byte_at(text, n)
  if not utf8 then
    return n + 1
  end
  return utf8.offset(text, n + 1) or (#text + 1)
end

--- Characters `from`..`to` (1-based, inclusive), clamped.
local function slice(text, from, to)
  local count = len(text)
  if from > count or to < from then
    return ""
  end
  to = math.min(to, count)
  return string.sub(text, byte_at(text, from - 1), byte_at(text, to) - 1)
end

--- `text` padded with spaces to `width` characters. Truncated if longer.
local function pad(text, width)
  local count = len(text)
  if count >= width then
    return slice(text, 1, width)
  end
  return text .. string.rep(" ", width - count)
end

-- ── colour ──────────────────────────────────────────────────────────────────
--
-- Roles only. `diff_added` / `diff_removed` / `branch_name` are part of the
-- 31-role palette carried over from v1, so this pane is themed by every one of
-- the 36 presets — and by any theme the user wrote — without anyone adding a
-- role for it.

local function role(name)
  return theme.role(name)
end

--- Foreground for a diff body line.
local function side_fg(side)
  if side == "add" then
    return role("diff_added")
  elseif side == "del" then
    return role("diff_removed")
  end
  return role("text_primary")
end

--- Background tint for a diff body line.
---
--- The palette carries `diff_added_bg` / `diff_removed_bg` for exactly this, and
--- a theme that leaves them undefined gets `nil` — "no colour" — rather than an
--- arbitrary one that would look deliberate.
local function side_bg(side)
  if side == "add" then
    return role("diff_added_bg")
  elseif side == "del" then
    return role("diff_removed_bg")
  end
  return nil
end

local function status_fg(status)
  if status == "A" then
    return role("diff_added")
  elseif status == "D" then
    return role("diff_removed")
  elseif status == "R" then
    return role("accent")
  end
  return role("status_working")
end
M.status_fg = status_fg

-- ── find highlighting ───────────────────────────────────────────────────────

--- Split `text` into runs, styling the parts that match `query`.
---
--- Case-insensitive and plain (`find(..., true)`), so a query containing `-`,
--- `(` or `.` — which is most queries in a diff — matches the characters typed
--- rather than being read as a pattern.
local function runs_for(text, style, query, hit_style)
  if not query or query == "" then
    return { { text = text, style = style } }
  end
  local haystack = string.lower(text)
  local runs, at = {}, 1
  while true do
    local from, to = string.find(haystack, query, at, true)
    if not from then
      break
    end
    if from > at then
      runs[#runs + 1] = { text = string.sub(text, at, from - 1), style = style }
    end
    runs[#runs + 1] = { text = string.sub(text, from, to), style = hit_style }
    at = to + 1
  end
  if at == 1 then
    return { { text = text, style = style } }
  end
  if at <= #text then
    runs[#runs + 1] = { text = string.sub(text, at), style = style }
  end
  return runs
end

--- The code half of a body line: syntax first, then the search match over it.
---
--- Order matters and it is this way round: syntax is a property of the text and
--- the match is a property of what you asked for, so the match WINS on the
--- characters it covers. The other way, a keyword inside a match would keep its
--- own colour and the match would look like it had a hole in it.
---
--- With no lang (highlighting off) this is exactly the single-colour path it
--- replaced, so the diff's own green and red are what a reader sees.
local function code_runs(text, base, opts, hit_style)
  local pieces
  if opts.lang then
    -- The add/remove signal has moved to the sign column and the row's tint, so
    -- the foreground belongs to the code. A SELECTED row keeps the selection's
    -- foreground instead: syntax colours over a selection background are
    -- unreadable in a good third of the themes.
    pieces = syntax.runs(text, opts.lang, base, opts.selected)
  else
    pieces = { { text = text, style = base } }
  end
  if not opts.query or opts.query == "" then
    return pieces
  end
  local out = {}
  for _, piece in ipairs(pieces) do
    for _, run in ipairs(runs_for(piece.text, piece.style, opts.query, hit_style)) do
      out[#out + 1] = run
    end
  end
  return out
end

-- ── the gutter ──────────────────────────────────────────────────────────────

--- Width of the line-number column, from the largest number the diff carries.
---
--- O(1): the parser keeps the largest number it has emitted, because scanning
--- every row for it was measured at 1.2M instructions on a capped diff — paid
--- on every frame the parse was still running.
---
--- It can still GROW while the parse is unfinished, which is correct: a gutter
--- frozen at the width the first eight thousand lines needed would misalign
--- every line after them.
function M.gutter_digits(parse)
  return math.max(2, len(tostring(parse.widest or 0)))
end

--- Columns the gutter occupies: two numbers, a space between them, and the
--- sign column that follows.
function M.gutter_width(digits)
  return digits * 2 + 3
end

--- The gutter text for a body line, or blank for a continuation row.
local function gutter_text(row, digits, blank)
  if blank then
    return string.rep(" ", digits * 2 + 1)
  end
  local old = row.old_no and tostring(row.old_no) or ""
  local new = row.new_no and tostring(row.new_no) or ""
  return string.rep(" ", digits - len(old))
    .. old
    .. " "
    .. string.rep(" ", digits - len(new))
    .. new
end

local SIGN = { add = "+", del = "-", ctx = " " }

-- ── one logical row -> its visual lines ─────────────────────────────────────

--- The body text of a row, as it would appear with no folding: what find
--- matches against, and what `send`-to-agent quotes.
function M.text_of(row, canonical)
  if row.kind == "pair" then
    -- Both halves, so a search finds a word on either side of the screen. The
    -- two are the same string for a context line, which pairs with itself.
    local old = row.old and canonical[row.old] and canonical[row.old].text or ""
    local new = row.new and canonical[row.new] and canonical[row.new].text or ""
    if old == new then
      return old
    end
    return old .. " " .. new
  end
  if row.kind == "file" then
    local name = row.path or ""
    if row.old_path then
      name = row.old_path .. " → " .. name
    end
    return name
  elseif row.kind == "hunk" then
    return row.heading or ""
  elseif row.kind == "line" then
    return row.text or ""
  end
  return row.text or ""
end

--- Expand one logical row into visual lines.
---
--- `into` collects `{ runs }`; the caller records the logical index against each.
--- Returns how many lines were appended, which is always at least one: a row
--- that produced none could not be selected, and the cursor would step over it.
local function expand(into, row, opts)
  local width = opts.width
  local selected = opts.selected
  local query = opts.query
  local sel_style = { fg = role("selection_fg"), bg = role("selection_bg"), bold = true }
  local hit_style = { fg = role("inverted_fg"), bg = role("accent_bright"), bold = true }

  -- A file header: the status glyph, the path, and the counts. Bold across the
  -- full width, which is what separates one file from the next — a blank row
  -- between them would be a logical row nothing could select, and the cursor
  -- would have to step over it.
  if row.kind == "file" then
    local base = selected and sel_style or { fg = role("text_primary"), bold = true }
    local mark = opts.reviewed and opts.reviewed[row.path] and "✓ " or "  "
    local name = M.text_of(row, nil)
    local counts = "  +" .. row.added .. " -" .. row.removed
    local head = mark .. row.status .. " "
    local body = pad(head .. name .. counts, width)
    if selected then
      into[#into + 1] = { { text = body, style = sel_style } }
    else
      -- Split so the status glyph and the counts take their own colours, and
      -- the path takes the plain one.
      local kept = slice(body, 1, width)
      local upto = len(head) + len(name)
      into[#into + 1] = {
        { text = slice(kept, 1, len(mark)), style = base },
        { text = slice(kept, len(mark) + 1, len(head)), style = { fg = status_fg(row.status) } },
        { text = slice(kept, len(head) + 1, upto), style = base },
        { text = slice(kept, upto + 1, width), style = { fg = role("text_muted") } },
      }
    end
    return 1
  end

  if row.kind == "hunk" then
    -- git's own header line, verbatim, plus the heading when there is one. A
    -- headingless hunk (every hunk of an added or deleted file) then still says
    -- exactly which lines it covers.
    local text = "@@ " .. (row.ranges or "") .. " @@"
    if row.heading and row.heading ~= "" then
      text = text .. " " .. row.heading
    end
    local style = selected and sel_style or { fg = role("accent"), bold = true }
    into[#into + 1] = { { text = pad(text, width), style = style } }
    return 1
  end

  if row.kind == "info" then
    into[#into + 1] = {
      { text = pad(row.text or "", width), style = { fg = role("text_muted"), italic = true } },
    }
    return 1
  end

  -- A paired row: two columns, one selectable unit.
  --
  -- This is where D2 is tested hardest — one logical row spanning two columns of
  -- cells — and it needed nothing new. Each half is the same gutter/sign/text it
  -- is in the unified layout, measured against half the width the kernel
  -- resolved, and a divider between them. The plugin knows the geometry, which
  -- is the whole claim of the surface.
  if row.kind == "pair" then
    local canonical = opts.canonical
    local half = math.max(1, math.floor((width - 1) / 2))
    local digits = opts.digits
    local gutter_w = M.gutter_width(digits)
    local body_w = math.max(1, half - gutter_w)

    --- One side's runs, or a blank column when that side has no line.
    local function side(index)
      local line = index and canonical[index]
      if not line then
        -- A change that added more lines than it removed leaves the old side
        -- blank on the overflow, and the reverse for a deletion. Blank, not
        -- absent: the row still has to be `half` wide or the divider walks.
        return {
          {
            text = string.rep(" ", half),
            style = { bg = selected and role("selection_bg") or nil },
          },
        }
      end
      local fg = selected and role("selection_fg") or side_fg(line.side)
      local bg = selected and role("selection_bg") or side_bg(line.side)
      -- ONE number, not two: a side-by-side column has only its own side to
      -- number, and printing both would spend a quarter of the column repeating
      -- what the other half already says.
      local number = tostring(line.old_no or line.new_no or "")
      local runs = {
        {
          text = string.rep(" ", math.max(0, digits * 2 + 1 - len(number))) .. number,
          style = selected and sel_style or { fg = role("text_muted"), bg = bg },
        },
        { text = SIGN[line.side] or " ", style = { fg = fg, bg = bg } },
        { text = " ", style = { fg = fg, bg = bg } },
      }
      local text = slice(line.text or "", 1, body_w)
      for _, run in
        ipairs(
          code_runs(
            text,
            { fg = fg, bg = bg, bold = selected or nil },
            { lang = opts.lang, query = query, selected = selected },
            selected and sel_style or hit_style
          )
        )
      do
        runs[#runs + 1] = run
      end
      local used = len(text)
      if used < body_w then
        runs[#runs + 1] = { text = string.rep(" ", body_w - used), style = { fg = fg, bg = bg } }
      end
      return runs
    end

    local left = side(row.old)
    local right = side(row.new)
    local runs = {}
    for _, run in ipairs(left) do
      runs[#runs + 1] = run
    end
    runs[#runs + 1] = {
      text = "│",
      style = { fg = role("border_unfocused"), bg = selected and role("selection_bg") or nil },
    }
    for _, run in ipairs(right) do
      runs[#runs + 1] = run
    end
    into[#into + 1] = runs
    return 1
  end

  -- A body line: gutter, sign, text.
  local digits = opts.digits
  local gutter_w = M.gutter_width(digits)
  local body_w = math.max(1, width - gutter_w)
  local sign = SIGN[row.side] or " "
  local text = row.text or ""

  local fg = selected and role("selection_fg") or side_fg(row.side)
  local bg = selected and role("selection_bg") or side_bg(row.side)
  local gutter_style = selected and sel_style or { fg = role("text_muted"), bg = bg }
  local body_style = { fg = fg, bg = bg, bold = selected or nil }
  local sign_style = { fg = selected and role("selection_fg") or side_fg(row.side), bg = bg }

  --- One visual line: gutter (or a blank one on continuations) + a slice.
  local function emit(chunk, continuation)
    local runs = {
      { text = gutter_text(row, digits, continuation), style = gutter_style },
      { text = continuation and " " or sign, style = sign_style },
      { text = " ", style = gutter_style },
    }
    for _, run in
      ipairs(
        code_runs(
          chunk,
          body_style,
          { lang = opts.lang, query = query, selected = selected },
          selected and sel_style or hit_style
        )
      )
    do
      runs[#runs + 1] = run
    end
    local used = len(chunk)
    if used < body_w then
      runs[#runs + 1] = { text = string.rep(" ", body_w - used), style = body_style }
    end
    into[#into + 1] = runs
  end

  if not opts.wrap then
    -- Horizontal scroll slides the body only; the gutter stays pinned, which is
    -- what makes it usable as a ruler while you are scrolled right.
    emit(slice(text, opts.hscroll + 1, opts.hscroll + body_w), false)
    return 1
  end

  local count = len(text)
  if count == 0 then
    emit("", false)
    return 1
  end
  local emitted, at = 0, 1
  while at <= count do
    emit(slice(text, at, at + body_w - 1), at > 1)
    at = at + body_w
    emitted = emitted + 1
  end
  return emitted
end

--- How many visual lines a logical row needs. Used by the scroll converger, so
--- it must agree with `expand` exactly — hence one expression, not two.
local function height_of(row, opts)
  -- A pair is one row, always: side-by-side does not wrap (v1 pins the
  -- horizontal scroll there too), because a wrapped half would have to push the
  -- other half's rows down to stay aligned, and the alignment IS the layout.
  if row.kind ~= "line" or not opts.wrap then
    return 1
  end
  local body_w = math.max(1, opts.width - M.gutter_width(opts.digits))
  local count = len(row.text or "")
  if count == 0 then
    return 1
  end
  return math.ceil(count / body_w)
end

-- ── the window ──────────────────────────────────────────────────────────────

--- Build the visible lines from logical row `first` down.
---
--- Returns `lines`, `logical` (one entry per line: the logical row it came
--- from), and the `first` actually used — which may have advanced, because with
--- wrapping on, a tall row above the cursor can push the cursor off the bottom
--- and the only fix is to start lower.
---
--- The converge loop is v1's, and bounded: it can only ever move `first` toward
--- `selected`, so it terminates, and the bound is belt-and-braces against a
--- future row kind that reports a height it does not produce.
function M.window(rows, first, opts)
  local height = opts.height
  local selected = opts.selected
  first = math.max(1, math.min(first, math.max(1, #rows)))

  for _ = 1, math.max(1, #rows) do
    local lines, logical = {}, {}
    local sel_first = nil
    for at = first, #rows do
      if #lines >= height then
        break
      end
      if at == selected then
        sel_first = #lines + 1
      end
      local row = rows[at]
      local produced = expand(lines, row, {
        width = opts.width,
        digits = opts.digits,
        wrap = opts.wrap,
        hscroll = opts.hscroll,
        query = opts.query,
        reviewed = opts.reviewed,
        -- The unified rows a paired row points into. Forwarded rather than read
        -- from a closure so `expand` stays a pure function of what it is handed.
        canonical = opts.canonical,
        -- Per ROW, because a diff spans files and its languages with them. Nil
        -- when highlighting is off, which is the whole switch.
        lang = opts.lang_of and opts.lang_of(row) or nil,
        selected = at == selected,
      })
      for _ = 1, produced do
        logical[#logical + 1] = at
      end
    end
    -- The cursor is below the fold: start one row lower and rebuild. Only
    -- reachable with wrapping on, where a row above can be many lines tall.
    if sel_first and sel_first > height and first < selected then
      first = first + 1
    elseif #lines < height and first > 1 then
      -- A SHORT PAGE with content above it: pull the window back so the last row
      -- sits at the bottom. Reachable whenever the row count shrinks under a
      -- remembered offset — switching to the paired layout nearly halves it, and
      -- a refresh to a smaller diff does the same — and the symptom is a body
      -- that draws a handful of lines with blank space beneath them.
      --
      -- Mutually exclusive with the branch above: a short page means everything
      -- fit, so the selection cannot also be below the fold.
      first = first - 1
    else
      while #lines > height do
        table.remove(lines)
        table.remove(logical)
      end
      return lines, logical, first
    end
  end
  return {}, {}, first
end

--- The `first` that brings `selected` into view from above, given `height`.
---
--- With wrapping off this is exact arithmetic. With it on, heights vary, so it
--- walks back from the selection accumulating heights — bounded by the height
--- itself, so it is a handful of iterations rather than a scan.
function M.scroll_to(rows, first, opts)
  local selected = opts.selected
  if selected < first then
    return selected
  end
  local used, at = 0, selected
  while at >= 1 do
    used = used + height_of(rows[at], opts)
    if used > opts.height then
      at = at + 1
      break
    end
    at = at - 1
  end
  return math.max(first, math.max(1, at))
end

M.slice = slice
M.pad = pad
M.len = len

return M
