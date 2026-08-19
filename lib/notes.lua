-- Review notes: what you write down while reading, and what gets sent.
--
-- ── Where they live, and the honest limit ───────────────────────────────────
--
-- In `state`, which is the plugin's own store. That means a note **survives a
-- reload (F10) and does not survive quitting thurbox**, because `state` is a map
-- the kernel holds in memory for the life of the process and never writes to
-- disk. The pane says so on screen rather than in this comment.
--
-- v1 persisted these in SQLite (`review_comments`, schema v38), and that storage
-- is still in the kernel, unused: it is not published to Lua and no command
-- writes it. Closing that is a kernel change, and `KERNEL-GAPS.md` §1 has the
-- shape. When it lands, only this file changes — the pane above it asks for
-- `notes.all(session)` and does not care where they came from.
--
-- Which is why they are worth having now rather than waiting: the workflow they
-- serve is one sitting. You read the diff, note what you find, and send the lot
-- to the agent — and `command("send", …)` has always worked, so nothing about
-- the SENDING is provisional.
--
-- ── Anchors ─────────────────────────────────────────────────────────────────
--
-- v1's three, kept: a note is on a line (a path, a side and a number), on a
-- file, or on the review. Anchored by PATH rather than by row index for the
-- reason everything else here is — the list a note was written against is not
-- the list it will be drawn in, once the layout or the folding changes.

local M = {}

--- v1's classifications, in its cycle order, with `note` the default.
M.CLASSES = { "issue", "suggestion", "note", "praise" }

M.LABEL = {
  issue = "Issue",
  suggestion = "Suggestion",
  note = "Note",
  praise = "Praise",
}

--- The next class in the cycle, wrapping. v1's `Classification::next`.
function M.next_class(class)
  for index, name in ipairs(M.CLASSES) do
    if name == class then
      return M.CLASSES[(index % #M.CLASSES) + 1]
    end
  end
  return M.CLASSES[1]
end

-- ── the store ───────────────────────────────────────────────────────────────
--
-- Every read of `state` builds a fresh table, so every one of these writes the
-- whole list back. That is the documented shape and it is why the list is kept
-- small and flat.

local function key(session)
  return "notes:" .. session
end

--- Every note for a session, in the order they were written.
function M.all(state, session)
  return state[key(session)] or {}
end

--- A counter that changes whenever the notes do.
---
--- The row list is cached against it, so drawing does not rebuild an interleave
--- of a hundred thousand rows on a frame where nothing was written.
function M.revision(state, session)
  return state["notesrev:" .. session] or 0
end

local function commit(state, session, list)
  state[key(session)] = list
  state["notesrev:" .. session] = M.revision(state, session) + 1
end

--- Add a note, returning its id.
function M.add(state, session, note)
  local list = M.all(state, session)
  local id = 0
  for _, held in ipairs(list) do
    id = math.max(id, held.id or 0)
  end
  note.id = id + 1
  list[#list + 1] = note
  commit(state, session, list)
  return note.id
end

function M.update(state, session, id, fields)
  local list = M.all(state, session)
  for _, note in ipairs(list) do
    if note.id == id then
      for name, value in pairs(fields) do
        note[name] = value
      end
    end
  end
  commit(state, session, list)
end

function M.remove(state, session, id)
  local list, out = M.all(state, session), {}
  for _, note in ipairs(list) do
    if note.id ~= id then
      out[#out + 1] = note
    end
  end
  commit(state, session, out)
end

function M.get(state, session, id)
  for _, note in ipairs(M.all(state, session)) do
    if note.id == id then
      return note
    end
  end
  return nil
end

-- ── anchoring ───────────────────────────────────────────────────────────────

--- What the row under the cursor anchors a note to.
---
--- A body line takes the NEW side when it has one, because that is the side a
--- reviewer is talking about nine times in ten — a deletion has only the old
--- side, and gets it. A file or hunk header anchors to the file, which is how
--- you say something about a file without picking a line in it.
function M.anchor_for(parse, rows, at)
  local row = rows[at]
  if not row then
    return nil
  end
  local file = row.file and parse.files[row.file]
  if not file then
    return nil
  end

  local line = nil
  if row.kind == "line" then
    line = row
  elseif row.kind == "pair" then
    line = parse.rows[row.new or row.old]
  end

  if line then
    if line.new_no then
      return { kind = "line", path = file.path, side = "new", line = line.new_no }
    end
    return { kind = "line", path = file.path, side = "old", line = line.old_no }
  end
  return { kind = "file", path = file.path }
end

--- Where a note is shown, as a lookup key. `nil` for a review note, which is
--- shown at the end rather than against a row.
local function anchor_key(note)
  if note.kind == "line" then
    return note.path .. "\1" .. note.side .. "\1" .. tostring(note.line)
  elseif note.kind == "file" then
    return note.path .. "\1file"
  end
  return nil
end

--- Every key a ROW answers to, so a note can be found for it by lookup.
---
--- Indexed rather than scanned: a linear search per row is O(rows x notes), and
--- `rows` is up to a hundred thousand.
---
--- A row can answer to TWO keys, and that is the point of returning a list. A
--- paired row carries a deletion and the addition that replaced it, so a note
--- written on either side in the unified layout has to find it — the first
--- version keyed a pair by its new side alone, and a note made on a deletion
--- disappeared the moment you pressed `v`. It was still stored and still
--- exported, which is the worst way for it to be missing.
local function row_keys(parse, row, into)
  local file = row.file and parse.files[row.file]
  if not file then
    return into
  end
  if row.kind == "file" then
    into[#into + 1] = file.path .. "\1file"
    return into
  end

  local function add(line)
    if not line then
      return
    end
    local side = line.new_no and "new" or "old"
    local number = line.new_no or line.old_no
    local key = file.path .. "\1" .. side .. "\1" .. tostring(number)
    -- A context line pairs with ITSELF, so both halves of the pair are the same
    -- row and would otherwise place the note twice.
    for _, held in ipairs(into) do
      if held == key then
        return
      end
    end
    into[#into + 1] = key
  end

  if row.kind == "line" then
    add(row)
  elseif row.kind == "pair" then
    -- Old first: it is the left column, and it reads first.
    add(row.old and parse.rows[row.old])
    add(row.new and parse.rows[row.new])
  end
  return into
end

-- ── interleaving ────────────────────────────────────────────────────────────

--- `base` with a `note` row after each row a note is anchored to, and the review
--- notes at the end under a heading.
---
--- A note row is a LOGICAL ROW like any other: selectable, one per note, and the
--- cursor stops on it. That is what lets `↵` edit one and `x` delete one without
--- either needing to know where it is on screen.
---
--- Cached on the parse against `signature`, which the caller builds from the
--- notes' revision and the layout, for the reason folding is: without it this is
--- a fresh table of every row, every frame.
function M.interleave(parse, base, list, signature)
  if parse.notes_key == signature and parse.noted_rows then
    return parse.noted_rows
  end
  if #list == 0 then
    parse.noted_rows, parse.notes_key = base, signature
    return base
  end

  local by_key, review = {}, {}
  for _, note in ipairs(list) do
    local at = anchor_key(note)
    if at then
      by_key[at] = by_key[at] or {}
      local bucket = by_key[at]
      bucket[#bucket + 1] = note
    else
      review[#review + 1] = note
    end
  end

  local out, keys = {}, {}
  for index = 1, #base do
    local row = base[index]
    out[#out + 1] = row
    for at = #keys, 1, -1 do
      keys[at] = nil
    end
    for _, at in ipairs(row_keys(parse, row, keys)) do
      local bucket = by_key[at]
      if bucket then
        for _, note in ipairs(bucket) do
          out[#out + 1] = { kind = "note", file = row.file, note = note }
        end
      end
    end
  end

  if #review > 0 then
    out[#out + 1] = { kind = "info", text = "Summary" }
    for _, note in ipairs(review) do
      out[#out + 1] = { kind = "note", note = note }
    end
  end

  parse.noted_rows, parse.notes_key = out, signature
  return out
end

--- Notes whose file is not in the diff any more.
---
--- Kept rather than dropped — a note is a thing you wrote — but they cannot be
--- shown against a row, so they are reported so the pane can say how many.
--- v1 omits them from its export; this counts them instead, because silently
--- dropping what somebody typed is the fault this pane keeps finding elsewhere.
function M.orphans(parse, list)
  local known = {}
  for _, file in ipairs(parse.files) do
    known[file.path] = true
  end
  local out = {}
  for _, note in ipairs(list) do
    if note.path and not known[note.path] then
      out[#out + 1] = note
    end
  end
  return out
end

return M
