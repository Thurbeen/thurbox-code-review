-- The unified-diff parser: `thurbox.diffs[id].body` -> a flat list of LOGICAL
-- rows.
--
-- This file is where the pane's central rule lives, so it is worth stating
-- before any code:
--
--   ONE LOGICAL DIFF ROW IS ONE SELECTABLE UNIT.
--
-- Everything downstream — the cursor, the scroll anchor, find matches, the
-- scrollbar thumb, every hitbox — is an index into the single flat list this
-- file returns. Wrapping and horizontal scrolling belong to `rows.lua`, which
-- expands a slice of that list into the VISUAL lines a surface is painted from.
-- A wrapped line is several visual rows and exactly one logical row, and the
-- moment those two ideas share a variable the rule is lost.
--
-- The parse mirrors `src/session/review.rs::parse_unified_diff` in the kernel,
-- including the parts that look like accidents and are not (see `metadata`).
-- The kernel already ran that parser to produce the per-file counts it
-- publishes; it does not publish the structure, so we re-derive it here from
-- the same bytes. Deriving it the same way is what keeps the file list and the
-- body from disagreeing about what is in the diff.
--
-- ── Why it parses a few thousand lines at a time ─────────────────────────────
--
-- A plugin call gets 20M Lua instructions (`kernel::host::INSTRUCTION_BUDGET`)
-- and a diff is capped at 4 MiB (`kernel::diff::MAX_DIFF_BYTES`), which is on
-- the order of 100k lines. So `advance` consumes a bounded number of lines per
-- call and the pane draws what exists so far. Ordinary diffs finish on the
-- first frame and nobody ever sees a partial one.
--
-- Measuring it moved the reason. A whole capped diff is ~10M instructions —
-- half the budget, so a single-shot parse would have survived it — but it is
-- also ~125 ms, which at 20fps is two and a half frames of a frozen interface.
-- The budget was the danger this was built against; the frame is the one it
-- actually protects. See `MEASUREMENTS.md`.
--
-- The cache is module-local, NOT in `state` or `store`: both hand back a fresh
-- copy on every read, so keeping a hundred thousand rows in either would cost
-- more per frame than reparsing from scratch.

local M = {}

--- Rows consumed per `advance` call.
---
--- MEASURED, not guessed. `MEASUREMENTS.md` beside this file records the run,
--- against the 4 MiB cap's worth of a real diff (99,041 lines):
---
---   the parse costs ~100 Lua instructions per line, linearly;
---   8000 lines is 8 of the 200 batches the kernel allows — 4% of the budget;
---   and it takes 10.1 ms, which is what actually decides the number.
---
--- The instruction budget turned out NOT to be the binding constraint. The
--- frame is: at 20fps a render has ~50 ms, and 16000 lines/frame measured 28.8
--- ms — inside the budget at 17 batches and visibly into the frame. So this is
--- set by wall clock, and a capped diff finishes in 13 frames (~0.65 s) rather
--- than in 4 stuttering ones.
M.LINES_PER_FRAME = 8000

-- ── row kinds ───────────────────────────────────────────────────────────────
--
-- `file`, `hunk` and `line` are selectable; `info` is not. v1 draws the same
-- four (`ReviewRow`), and `is_selectable` is the same predicate.

--- Is this row a cursor stop?
function M.selectable(row)
  return row ~= nil and row.kind ~= "info"
end

-- ── scanning helpers ────────────────────────────────────────────────────────

--- Start line of a `start,count` (or bare `start`) range token.
---
--- Mirrors `parse_start`: everything from the comma on is the count, which the
--- row numbering does not need because it counts the lines it actually sees.
local function range_start(token)
  local head = string.match(token, "^([0-9]+)")
  return tonumber(head) or 0
end

--- `@@ -o,os +n,ns @@ heading` -> old start, new start, heading.
---
--- The heading is what git puts after the second `@@` — usually the enclosing
--- function — and it is the most useful thing on the row, so it is kept whole
--- rather than being reduced to the line numbers.
local function hunk_header(line)
  local after = string.match(line, "^@@ (.*)$")
  if not after then
    return 0, 0, "", ""
  end
  local ranges, heading = string.match(after, "^(.-) @@(.*)$")
  if not ranges then
    return 0, 0, "", ""
  end
  local old_start, new_start = 0, 0
  for token in string.gmatch(ranges, "%S+") do
    local minus = string.match(token, "^%-(.*)$")
    local plus = string.match(token, "^%+(.*)$")
    if minus then
      old_start = range_start(minus)
    elseif plus then
      new_start = range_start(plus)
    end
  end
  return old_start, new_start, (string.gsub(heading, "^%s*(.-)%s*$", "%1")), ranges
end

--- Split the tail of a `diff --git a/<old> b/<new>` line.
---
--- Best-effort, exactly as the kernel's is: git quotes paths containing special
--- characters, and the `---`/`+++` lines that follow refine both paths anyway.
local function git_paths(rest)
  local at = string.find(rest, " b/", 1, true)
  if not at then
    return nil, nil
  end
  local old = string.match(string.sub(rest, 1, at - 1), "^a/(.*)$")
  local new = string.match(string.sub(rest, at + 1), "^b/(.*)$")
  return old, new
end

--- Apply a file-header metadata line to the file being built, returning whether
--- it was consumed.
---
--- `in_hunk` gates the `---`/`+++` arms to the region BEFORE the first hunk, and
--- that gate is load-bearing rather than tidy: inside a hunk, a removed line
--- whose own content begins `-- ` (a Lua, SQL or Haskell comment) arrives as
--- `--- …` and must stay a deletion. Without the gate it is silently eaten as a
--- header and the file appears to have fewer removals than it has. The kernel's
--- parser carries the same gate and the same comment.
local function metadata(file, line, in_hunk)
  if string.sub(line, 1, 13) == "new file mode" then
    file.status = "A"
  elseif string.sub(line, 1, 17) == "deleted file mode" then
    file.status = "D"
  else
    local from = string.match(line, "^rename from (.*)$")
    local to = string.match(line, "^rename to (.*)$")
    local old = (not in_hunk) and string.match(line, "^%-%-%- (.*)$") or nil
    local new = (not in_hunk) and string.match(line, "^%+%+%+ (.*)$") or nil
    if from then
      file.status = "R"
      file.old_path = from
    elseif to then
      file.status = "R"
      file.path = to
    elseif old then
      old = string.gsub(old, "^%s*(.-)%s*$", "%1")
      if old ~= "/dev/null" then
        local stripped = string.match(old, "^a/(.*)$") or old
        if not file.old_path and file.path ~= stripped then
          file.old_path = stripped
        end
      end
    elseif new then
      new = string.gsub(new, "^%s*(.-)%s*$", "%1")
      if new ~= "/dev/null" then
        file.path = string.match(new, "^b/(.*)$") or new
      end
    else
      return false
    end
  end
  return true
end

-- ── the incremental parse ───────────────────────────────────────────────────

--- A fresh parse over `body`.
local function new_parse(body)
  return {
    body = body,
    at = 1, -- next line of `body` to read
    rows = {}, -- the flat logical-row list, the thing this file exists for
    files = {}, -- one entry per changed file, in diff order
    file = nil, -- the file row currently being filled in
    index = 0, -- its index in `files`
    hunk = 0, -- hunk ordinal within the current file
    in_hunk = false,
    old_no = 0,
    new_no = 0,
    -- The largest line number seen so far, kept as rows are appended so the
    -- gutter width costs nothing. Scanning every row for it once per frame was
    -- measured at 1.2M instructions on a capped diff — paid on every frame of
    -- the incremental parse, for a number the parser already had in its hand.
    widest = 0,
    done = false,
  }
end

--- Consume one body line.
local function step(parse, line)
  local rest = string.match(line, "^diff %-%-git (.*)$")
  if rest then
    local old, new = git_paths(rest)
    parse.index = parse.index + 1
    parse.hunk = 0
    parse.in_hunk = false
    local file = {
      kind = "file",
      file = parse.index,
      path = new or old or "",
      old_path = nil,
      status = "M",
      added = 0,
      removed = 0,
    }
    parse.file = file
    parse.files[parse.index] = file
    parse.rows[#parse.rows + 1] = file
    return
  end

  local file = parse.file
  if not file then
    -- Output before the first `diff --git` header. git emits none, but a
    -- truncated body can begin mid-stream, so it is dropped rather than
    -- guessed at.
    return
  end

  if string.sub(line, 1, 2) == "@@" then
    local old_start, new_start, heading, ranges = hunk_header(line)
    parse.hunk = parse.hunk + 1
    parse.in_hunk = true
    parse.old_no = old_start
    parse.new_no = new_start
    parse.rows[#parse.rows + 1] = {
      kind = "hunk",
      file = parse.index,
      hunk = parse.hunk,
      heading = heading,
      -- git's own `-o,os +n,ns`, kept verbatim. A hunk with no heading — every
      -- hunk of a new or deleted file has none — otherwise had to invent a
      -- label, and the first attempt invented "line 0" for a deletion, which is
      -- not a line anybody can go and look at.
      ranges = ranges,
      old_start = old_start,
      new_start = new_start,
    }
    return
  end

  if metadata(file, line, parse.in_hunk) then
    return
  end

  if not parse.in_hunk then
    -- `index …`, `similarity …`, `Binary files … differ`. Nothing to number.
    return
  end

  local first = string.sub(line, 1, 1)
  local side, old_no, new_no
  if first == "+" then
    side, new_no = "add", parse.new_no
    parse.new_no = parse.new_no + 1
    file.added = file.added + 1
  elseif first == "-" then
    side, old_no = "del", parse.old_no
    parse.old_no = parse.old_no + 1
    file.removed = file.removed + 1
  elseif first == " " then
    side, old_no, new_no = "ctx", parse.old_no, parse.new_no
    parse.old_no = parse.old_no + 1
    parse.new_no = parse.new_no + 1
  else
    -- `\ No newline at end of file`, and anything else that is not a body
    -- line. Skipped, as the kernel's parser skips it.
    return
  end

  local highest = math.max(old_no or 0, new_no or 0)
  if highest > parse.widest then
    parse.widest = highest
  end

  parse.rows[#parse.rows + 1] = {
    kind = "line",
    file = parse.index,
    hunk = parse.hunk,
    side = side,
    old_no = old_no,
    new_no = new_no,
    text = string.sub(line, 2),
  }
end

--- Parse up to `budget` more lines. Returns the parse, done or not.
local function advance(parse, budget)
  local body, at = parse.body, parse.at
  local last = math.min(#body, at + budget - 1)
  for index = at, last do
    step(parse, body[index])
  end
  parse.at = last + 1
  if parse.at > #body then
    parse.done = true
  end
  return parse
end

-- ── the cache ───────────────────────────────────────────────────────────────
--
-- Keyed per session, and thrown away when the body underneath changes.

local cache = {}

--- Sixteen samples plus the length: enough to notice a body that changed
--- without changing its line count, at O(1) per frame rather than O(lines).
---
--- It is deliberately NOT the only guard. `epoch` below is the exact one; this
--- is what catches a change that somehow reached us without passing through a
--- non-ready state.
local function fingerprint(body)
  local count = #body
  local parts = { count }
  local stride = math.max(1, math.floor(count / 16))
  for index = 1, count, stride do
    local line = body[index]
    parts[#parts + 1] = #line
    parts[#parts + 1] = string.sub(line, 1, 24)
  end
  parts[#parts + 1] = body[count] or ""
  return table.concat(parts, "\1")
end

--- The parse of `session`'s current diff, advanced by one frame's budget.
---
--- Call it every frame. A finished parse is returned as it is; an unfinished one
--- takes another `LINES_PER_FRAME` bite and comes back with `done = false`, and
--- the pane draws the part that exists.
---
--- `epoch` is the exact invalidation. A diff's content can only change by the
--- store dropping its entry and recomputing, which means the pane must observe a
--- frame that is not `ready` in between (absent, then `pending`). Counting those
--- transitions identifies a body precisely, and costs one comparison — where
--- hashing the body itself would cost a pass over every line, every frame, for a
--- diff that almost never changes.
function M.parse(session, body, epoch)
  local held = cache[session]
  if held and held.epoch == epoch and held.print == fingerprint(body) then
    if not held.parse.done then
      advance(held.parse, M.LINES_PER_FRAME)
    end
    return held.parse
  end

  local parse = advance(new_parse(body), M.LINES_PER_FRAME)
  cache[session] = { epoch = epoch, print = fingerprint(body), parse = parse }
  return parse
end

--- How far a parse has got, as a fraction. Only ever shown while it is < 1.
function M.progress(parse)
  local count = #parse.body
  if count == 0 then
    return 1
  end
  return math.min(1, (parse.at - 1) / count)
end

--- Forget everything cached for a session, so the next parse starts over.
---
--- Called when the pane asks for a refresh, so a recomputed diff of exactly the
--- same shape is still re-read rather than being served from the old parse.
function M.forget(session)
  cache[session] = nil
end

-- ── the side-by-side view ───────────────────────────────────────────────────
--
-- A second flat list over the same parse, and it has to BE a second list rather
-- than a rendering trick, because side-by-side changes what a selectable unit
-- is: a deletion and the addition that replaced it share one row. Pairing only
-- at paint time would leave two logical rows behind one visual one, so `j` would
-- move the highlight every other press — which is the rule in this file's header
-- breaking quietly.
--
-- v1 draws the same conclusion (`session::review::pair_hunk`) and this mirrors
-- its algorithm exactly, positional alignment and all: cheap, deterministic, and
-- language-agnostic, matching the stance already taken for syntax highlighting.

--- Pair the run of `line` rows starting at `from`, appending to `into`.
---
--- Returns the index just past the run. Deletions come before additions within a
--- contiguous change — git emits them that way — so the run is read as "the dels,
--- then the adds", and they are aligned by position. An uneven remainder leaves
--- one half blank, which is what a change that added more lines than it removed
--- looks like.
local function pair_run(rows, from, into)
  local at = from
  while at <= #rows and rows[at].kind == "line" do
    local row = rows[at]
    if row.side == "ctx" then
      -- A context line pairs with itself: the same text on both sides.
      into[#into + 1] = { kind = "pair", file = row.file, hunk = row.hunk, old = at, new = at }
      at = at + 1
    else
      local del_from = at
      while at <= #rows and rows[at].kind == "line" and rows[at].side == "del" do
        at = at + 1
      end
      local del_count = at - del_from
      local add_from = at
      while at <= #rows and rows[at].kind == "line" and rows[at].side == "add" do
        at = at + 1
      end
      local add_count = at - add_from
      for k = 0, math.max(del_count, add_count) - 1 do
        into[#into + 1] = {
          kind = "pair",
          file = rows[del_from].file,
          hunk = rows[del_from].hunk,
          old = k < del_count and (del_from + k) or nil,
          new = k < add_count and (add_from + k) or nil,
        }
      end
      -- A run of neither (nothing else is a `line`) would spin; `at` always
      -- advances above because the outer loop only enters on a `line` row.
      if at == del_from then
        at = at + 1
      end
    end
  end
  return at
end

--- The paired rows for `parse`, cached and rebuilt as the parse grows.
---
--- File, hunk and informational rows carry through unchanged: they span both
--- columns, so pairing has nothing to do with them.
function M.paired(parse)
  if parse.paired and parse.paired_at == parse.at then
    return parse.paired
  end
  local rows, out = parse.rows, {}
  local at = 1
  while at <= #rows do
    if rows[at].kind == "line" then
      at = pair_run(rows, at, out)
    else
      out[#out + 1] = rows[at]
      at = at + 1
    end
  end
  parse.paired, parse.paired_at = out, parse.at
  return out
end

--- The canonical (unified) row a row in either list stands for.
---
--- A pair stands for its old side, or its new side when the change only added.
--- Everything else is itself.
local function anchor_of(rows, at)
  local row = rows[at]
  if not row then
    return nil
  end
  if row.kind == "pair" then
    return row.old or row.new
  end
  return at
end

--- Move a cursor from one list to the other, landing on the row that holds the
--- same diff line.
---
--- Without it, toggling the layout leaves the index pointing wherever it happens
--- to land in a list of a different length — which on a hunk with many deletions
--- is a different file.
---
--- `parse` is passed so the direction is known rather than guessed: both lists
--- carry file and hunk rows, so "does this list contain pairs" is not a test.
function M.remap(parse, from_rows, at, to_rows)
  local want = from_rows[at]
  if not want then
    return 1
  end
  local anchor = anchor_of(from_rows, at)

  -- To the unified list, the anchor IS the index, by construction — every row
  -- of `parse.rows` stands for itself.
  if to_rows == parse.rows then
    return anchor and math.max(1, math.min(anchor, #to_rows)) or 1
  end

  -- To the paired list: a line is inside a pair, and a file or hunk row was
  -- carried through by reference, so identity finds it.
  for index = 1, #to_rows do
    local row = to_rows[index]
    if row == want then
      return index
    end
    if row.kind == "pair" and (row.old == anchor or row.new == anchor) then
      return index
    end
  end
  return math.max(1, math.min(at, #to_rows))
end

-- ── folding ─────────────────────────────────────────────────────────────────
--
-- A folded file contributes only its header row, like a collapsed tree node.
-- v1's `rebuild_rows` does the same thing, and its rule for WHICH files are
-- folded is worth keeping exactly: `reviewed XOR override`. Marking a file seen
-- folds it, because the point of marking it is that you are done with it; the
-- override then lets you peek into a file you have marked, or fold one you have
-- not, without either action changing the mark.
--
-- Filtering happens over whichever list is in force, so it composes with the
-- side-by-side view rather than being a third one.

--- `base` with the rows of folded files removed, keeping their headers.
---
--- Cached on the parse against `signature`, which the caller builds from the set
--- of folded paths and the layout. Without that this is a fresh table of up to a
--- hundred thousand entries per frame, for a set that changes when a key is
--- pressed and not otherwise.
function M.unfolded(parse, base, is_folded, signature)
  if parse.fold_key == signature and parse.folded_rows then
    return parse.folded_rows
  end
  local out, hidden = {}, nil
  for at = 1, #base do
    local row = base[at]
    if row.kind == "file" then
      hidden = is_folded(row.path) and row.file or nil
      out[#out + 1] = row
    elseif hidden == nil or row.file ~= hidden then
      -- `hidden == nil` first, because a row belonging to NO file — the summary
      -- heading, and a note about the review rather than a line — has
      -- `row.file == nil`, and `nil ~= nil` is false. Without the guard those
      -- rows were dropped whenever anything at all was folded, which is the one
      -- state where a reviewer is most likely to be writing a summary.
      out[#out + 1] = row
    end
  end
  parse.folded_rows, parse.fold_key = out, signature
  return out
end

-- ── navigation over the flat list ───────────────────────────────────────────
--
-- Every one of these is an index into `rows`. Nothing here knows that a row can
-- occupy more than one line on screen, which is the point.

--- The first row of the file at `path`, or nil when the body does not carry it.
---
--- Keyed on the PATH, not on an index. The two file lists in play — the kernel's
--- (from `--numstat`/`--name-status`, complete) and this parse's (from the
--- capped body) — used to come from one parse over one set of bytes, so index
--- `n` meant the same file in both. Since the kernel began listing files
--- independently of the body that is no longer true, and a capped diff makes
--- them disagree by hundreds. The path is the only join that survives, which is
--- also the join a comment anchor needs.
function M.file_row(rows, path)
  for at = 1, #rows do
    local row = rows[at]
    if row.kind == "file" and row.path == path then
      return at
    end
  end
  return nil
end

--- The paths the body actually carries, as a set.
---
--- A capped body holds fewer files than the list beside it, and the difference
--- is not an error — it is what `truncated` means, now that the list is whole.
--- Computed once per finished parse.
function M.covered(parse)
  if parse.covered and parse.covered_at == parse.at then
    return parse.covered
  end
  local set = {}
  for _, file in ipairs(parse.files) do
    set[file.path] = true
  end
  parse.covered, parse.covered_at = set, parse.at
  return set
end

--- The next row at or after `from` whose kind is in `kinds`, searching in
--- `direction` (1 or -1). Returns nil at the ends rather than wrapping: v1 stops
--- at the last file, and a jump that silently wrapped to the top would read as
--- the key having done nothing.
function M.jump(rows, from, kinds, direction)
  local at = from + direction
  while at >= 1 and at <= #rows do
    if kinds[rows[at].kind] then
      return at
    end
    at = at + direction
  end
  return nil
end

--- The PATH of the file a row belongs to, for the changed-files highlight.
--- `nil` for rows that belong to no file (the informational ones).
---
--- A path rather than an index, for the reason `file_row` takes one: the list
--- this highlight is drawn in is not the list these rows were built from.
---
--- Takes the rows in force, since there are two lists now — the unified one and
--- the paired one — and a cursor indexes whichever is on screen.
function M.path_of(parse, rows, at)
  local row = rows[at]
  local file = row and row.file and parse.files[row.file]
  return file and file.path or nil
end

return M
