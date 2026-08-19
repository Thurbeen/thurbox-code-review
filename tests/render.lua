-- The pane's `render`, called directly, against a faked snapshot.
--
-- Between `tests/modules.lua` (the pure modules) and `tests/render-proof.sh` (a
-- real thurbox in a real terminal) there was a gap: the tree the pane RETURNS.
-- A screenshot shows what was painted but not why, and chasing "the footer is
-- the wrong one" through captures is slow and inconclusive. This calls `render`
-- and asserts on the node tree, which is where the answer actually is.
--
-- Run it through `tests/run.sh --render`.

local REPO = assert(os.getenv("REPO"), "REPO=")
local UI = assert(os.getenv("UI"), "UI=")

-- ── the environment the plugin VM provides ──────────────────────────────────

local roles = {}
for _, name in ipairs({
  "accent",
  "accent_bright",
  "status_working",
  "status_blocked",
  "status_done",
  "status_idle",
  "status_error",
  "status_unreachable",
  "text_primary",
  "text_secondary",
  "text_muted",
  "border_focused",
  "border_unfocused",
  "role_name",
  "branch_name",
  "search_bar",
  "keybind_hint",
  "tool_allowed",
  "tool_disallowed",
  "danger",
  "selection_bg",
  "selection_fg",
  "modal_dim_bg",
  "modal_bg",
  "modal_border",
  "inverted_fg",
  "diff_added",
  "diff_removed",
  "diff_added_bg",
  "diff_removed_bg",
  "app_bg",
}) do
  roles[name] = "#" .. string.format("%06x", #name * 111111 % 0xffffff)
end

-- `state` and `store` hand back a COPY on every read in the real VM. Copying
-- here too, so a test cannot pass on a mutation the real one would discard.
local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function shared_table(backing)
  return setmetatable({}, {
    __index = function(_, key)
      return deep_copy(backing[key])
    end,
    __newindex = function(_, key, value)
      backing[key] = deep_copy(value)
    end,
  })
end

local state_backing, store_backing = {}, {}
_G.state = shared_table(state_backing)
_G.store = shared_table(store_backing)

--- The declared settings, as the registry publishes them.
---
--- The stub APPLIES `command("set", …)` rather than only recording it, because
--- the pane's view toggles are settings now — there is no `state` shadow to
--- assert against, and a stub that swallowed the write would make every toggle
--- look broken.
---
--- Applied immediately where the kernel applies it a frame later. That is the
--- one place this stub is kinder than the real thing, and it is noted so a test
--- that depends on the delay is not written here by accident.
local settings = {}
local commands = {}
_G.command = function(kind, args)
  commands[#commands + 1] = { kind = kind, args = args }
  if kind == "set" and args and args.text then
    local plugin, id = string.match(args.text, "^(.-)%.(.+)$")
    for _, entry in ipairs(settings) do
      if entry.plugin == plugin and entry.id == id then
        entry.value = args.reset and nil or args.flag
        return
      end
    end
    settings[#settings + 1] = { plugin = plugin, id = id, value = args.reset and nil or args.flag }
  end
end

-- ── programs, and the trust that gates them ─────────────────────────────────
--
-- `run` is a GLOBAL that is simply absent until the plugin is trusted — that is
-- capability-by-absence, and the pane's untrusted path is `if not run then`. So
-- the harness has to be able to take it away, not merely to make it fail.

local runs_backing, asked = {}, {}

local function grant_run(granted)
  if granted then
    _G.run = function(key, program, opts)
      asked[#asked + 1] = { key = key, program = program, opts = opts or {} }
    end
  else
    _G.run = nil
  end
end

--- Publish an answer for a key, as `thurbox.runs` would carry it.
local function answers(key, fields)
  runs_backing[key] = fields
end

--- Every program asked for since the last `forget_runs`, as one string.
local function programs_asked()
  local out = {}
  for _, one in ipairs(asked) do
    out[#out + 1] = one.program
  end
  return table.concat(out, "\n")
end

local function forget_runs()
  for key in pairs(runs_backing) do
    runs_backing[key] = nil
  end
  for index = #asked, 1, -1 do
    asked[index] = nil
  end
end

local real_require, loaded = require, {}
_G.require = function(name)
  if loaded[name] then
    return loaded[name]
  end
  local path
  if name:match("^thurbox%-code%-review%.") then
    path = REPO .. "/" .. name:gsub("^thurbox%-code%-review%.", ""):gsub("%.", "/") .. ".lua"
  elseif name:match("^lib%.") then
    path = UI .. "/" .. name:gsub("%.", "/") .. ".lua"
  else
    return real_require(name)
  end
  local value = assert(loadfile(path), "cannot load " .. path)()
  loaded[name] = value
  return value
end

-- ── the snapshot ────────────────────────────────────────────────────────────

local SESSION = { id = "s1", name = "demo", base_branch = "main", branch = "demo/x" }

--- Which pane the snapshot says holds focus. The pane reads it to decide
--- whether its own key is an enter or a leave.
local focused_pane = "agent"

local function snapshot(diff)
  _G.thurbox = {
    sessions = { SESSION },
    diffs = diff and { s1 = diff } or {},
    theme = { name = "test", roles = roles },
    -- The registry the pane reads chords out of. `sessions.toggle_panel` is
    -- here because the border's `F9` hint is looked up rather than written —
    -- rebinding the toggle relabels the border, so an empty registry correctly
    -- draws a chevron with no chord and would make that assertion vacuous.
    registry = {
      settings = settings,
      keys = { { action = "sessions.toggle_panel", key = "f9", plugin = "sessions" } },
    },
    settings = {},
    -- The interface's own inventory, which is how the pane finds what shares
    -- its slot. Two occupants of `center`, as the stock arrangement has.
    plugins = {
      { name = "sessions", slot = "sessions", kind = "pane", state = "visible" },
      { name = "agent", slot = "center", kind = "pane", state = "visible" },
      { name = "review", slot = "center", kind = "pane", state = "hidden" },
    },
    focus = focused_pane,
    -- Answers to the programs THIS plugin asked for. Empty unless a test filled
    -- it, which is the same as a run that has not finished.
    runs = runs_backing,
  }
  store_backing.selected = "s1"
end

--- A body of `files` files with `lines` changed lines each.
local function body_of(files, lines)
  local out = {}
  for f = 1, files do
    out[#out + 1] = "diff --git a/pkg/file" .. f .. ".txt b/pkg/file" .. f .. ".txt"
    out[#out + 1] = "index 1111111..2222222 100644"
    out[#out + 1] = "--- a/pkg/file" .. f .. ".txt"
    out[#out + 1] = "+++ b/pkg/file" .. f .. ".txt"
    out[#out + 1] = "@@ -1," .. lines .. " +1," .. lines .. " @@"
    for i = 1, lines do
      out[#out + 1] = "-old line " .. i .. " of file " .. f
    end
    for i = 1, lines do
      out[#out + 1] = "+new line " .. i .. " of file " .. f
    end
  end
  return out
end

local function ready(files, lines, extra)
  local list = {}
  for f = 1, files do
    list[f] = { path = "pkg/file" .. f .. ".txt", added = lines, removed = lines, status = "M" }
  end
  local entry = { state = "ready", files = list, body = body_of(files, lines), truncated = false }
  for k, v in pairs(extra or {}) do
    entry[k] = v
  end
  return entry
end

-- ── walking the returned tree ───────────────────────────────────────────────

local function walk(node, visit)
  if type(node) ~= "table" then
    return
  end
  visit(node)
  for _, child in ipairs(node.children or {}) do
    walk(child, visit)
  end
end

--- Every string in the tree, joined per text node.
local function texts(node)
  local out = {}
  walk(node, function(item)
    if item.type ~= "text" then
      return
    end
    for _, line in ipairs(type(item.text) == "table" and item.text or {}) do
      local parts = {}
      for _, run in ipairs(line) do
        parts[#parts + 1] = run.text or ""
      end
      out[#out + 1] = table.concat(parts)
    end
    if type(item.text) == "string" then
      out[#out + 1] = item.text
    end
  end)
  return out
end

local function joined(node)
  return table.concat(texts(node), "\n")
end

--- Every node kind used, so D3 is asserted rather than believed.
local function kinds(node)
  local seen = {}
  walk(node, function(item)
    if item.type then
      seen[item.type] = true
    end
  end)
  return seen
end

local function surface_cells(node)
  local found
  walk(node, function(item)
    if item.type == "surface" and item.cells then
      found = item.cells
    end
  end)
  return found
end

--- The body's lines as strings.
---
--- `texts` cannot see them: it walks `text` NODES, and the body is a surface
--- whose cells never become nodes. Anything asserting about what the diff shows
--- has to come through here — which is the tree/surface split showing up in the
--- tests exactly as it does in the pane.
local function body_texts(node)
  local out = {}
  for _, line in ipairs(surface_cells(node) or {}) do
    local parts = {}
    for _, run in ipairs(line) do
      parts[#parts + 1] = run.text or ""
    end
    out[#out + 1] = table.concat(parts)
  end
  return out
end

--- Forget everything the pane remembers about a session.
---
--- Blocks share one `state`, and the pane keeps marks, folds, cursors and
--- queries per session — so a block that runs after the folding one inherits two
--- collapsed files and a cursor sitting on a header. The first note written here
--- anchored to a FILE instead of a line for exactly that reason, and the pane
--- was right both times. A test that starts from whatever the last one left is
--- testing an accident.
local function forget(session)
  -- The PARSE goes too. It carries the lists derived from this state — the
  -- interleaved rows, the folded rows — keyed on counters that start again from
  -- zero when the state is cleared. Without this, a block that resets and then
  -- writes one note collides with the cache key of the block before it and is
  -- served that block's rows. Nothing in the pane resets those counters; only a
  -- test does, which is exactly why the test has to clear both halves.
  -- Every SCOPE of it: the parse is keyed by session and target together, so
  -- `forget(session)` alone left the previous block's rows behind the key the
  -- next block would build.
  require("thurbox-code-review.lib.diff").forget_all(session)
  require("thurbox-code-review.lib.target").forget(session)
  for _, prefix in ipairs({
    "sel:",
    "top:",
    "hscroll:",
    "marks:",
    "fold:",
    "notes:",
    "notesrev:",
    "compose:",
    "find:",
    "typing:",
    "query:",
    "list:",
    "target:",
    "picker:",
  }) do
    -- Both the plain key and every SCOPED one. Per-review state is keyed by
    -- session AND target now (`sel:s1\1commit:abc1234`), so clearing only
    -- `sel:s1` would leave a cursor behind for every target the block visited —
    -- and the next block would start on it, which is the accident this exists to
    -- prevent.
    local stem = prefix .. session
    for key in pairs(state_backing) do
      if key == stem or string.sub(key, 1, #stem + 1) == stem .. "\1" then
        state_backing[key] = nil
      end
    end
  end
end

--- The scope the pane keys per-review state by, for the kernel's own target.
---
--- Spelled out in ONE place: a test that hardcodes `sel:s1` in six places is six
--- things to fix the next time the key changes, and five of them will be found
--- by a failure rather than by looking.
local DEFAULT_SCOPE = require("thurbox-code-review.lib.target").scope("", nil)

--- The body line the cursor is on, found by its selection background.
---
--- The right oracle for "did the jump land": asking whether a file is the LAST
--- line only works when the body overflows its window, and a short diff fits
--- whole — so that assertion passed for the large fixture and failed for the
--- small one while the pane was behaving identically in both.
local function selected_line(node)
  local want = roles.selection_bg
  for _, line in ipairs(surface_cells(node) or {}) do
    for _, run in ipairs(line) do
      if run.style and run.style.bg == want then
        local text = {}
        for _, part in ipairs(line) do
          text[#text + 1] = part.text or ""
        end
        return table.concat(text)
      end
    end
  end
  return nil
end

local rows_len = require("thurbox-code-review.lib.rows").len

local function ids(node)
  local out = {}
  walk(node, function(item)
    if item.id then
      out[#out + 1] = item.id
    end
  end)
  return out
end

--- The changed-files list's ids only.
---
--- Separate from `ids` because the diff BODY carries one too — a `surface` with
--- an `id`, which is how a click on it reaches the pane — and counting it as a
--- file row made two assertions about the list off by one.
local function file_ids(node)
  local out = {}
  for _, id in ipairs(ids(node)) do
    if id:match("^file:") then
      out[#out + 1] = id
    end
  end
  return out
end

-- ── the runner ──────────────────────────────────────────────────────────────

local failures, count = 0, 0
local function check(name, ok, detail)
  count = count + 1
  if ok then
    print(string.format("  ok   %s", name))
  else
    failures = failures + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -- " .. detail) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end
local function has(name, text, needle)
  check(name, text:find(needle, 1, true) ~= nil, "missing " .. needle)
end
local function hasnt(name, text, needle)
  check(name, text:find(needle, 1, true) == nil, "unexpectedly present: " .. needle)
end

local target_lib = require("thurbox-code-review.lib.target")
local plugin = assert(loadfile(REPO .. "/plugins/40_review.lua"))()
local CTX = { width = 120, height = 40, focused = true, elapsed = 0 }

local function render(ctx)
  return plugin.render(ctx or CTX)
end

-- ── the states ──────────────────────────────────────────────────────────────

print("== the states are distinguishable ==")
do
  snapshot(nil)
  local absent = joined(render())
  has("no entry says it is asking", absent, "Asking for the diff")

  snapshot({ state = "pending" })
  local pending = joined(render())
  has("pending says it is building", pending, "Building diff")
  hasnt("pending is not 'No changes'", pending, "No changes")

  snapshot({ state = "failed", error = "could not read the diff" })
  local failed = joined(render())
  has("failed reports the kernel's reason", failed, "could not read the diff")

  snapshot({ state = "ready", files = {}, body = {}, truncated = false })
  local empty = joined(render())
  has("empty says no changes", empty, "No changes")
  has("empty names the range", empty, "main..HEAD")
  hasnt("empty is not 'Building'", empty, "Building diff")
end

print("== four node kinds, and no fifth ==")
do
  snapshot(ready(3, 5))
  local used = kinds(render())
  for kind in pairs(used) do
    check("kind '" .. kind .. "' is one of the four", ({
      text = true,
      box = true,
      input = true,
      surface = true,
    })[kind] ~= nil)
  end
  check("the body is a surface", used.surface == true)
  check("the tree is text in a box", used.text == true and used.box == true)
end

print("== the body is a surface of exactly the rows that fit ==")
do
  snapshot(ready(3, 40))
  for _, height in ipairs({ 10, 24, 40 }) do
    local cells =
      surface_cells(render({ width = 120, height = height, focused = true, elapsed = 0 }))
    check(
      "height " .. height .. ": the surface is handed at most the rows it has",
      cells ~= nil and #cells <= height,
      cells and ("got " .. #cells) or "no surface"
    )
  end
end

print("== the changed-files list carries identity ==")
do
  snapshot(ready(3, 5))
  local found = file_ids(render())
  eq("one id per file", #found, 3)
  eq("named by path, not by index", found[1], "file:pkg/file1.txt")
end

print("== the footer offers the pane's keys once a diff is on screen ==")
do
  -- The regression this file was written for. A capture showed the not-ready
  -- footer while a diff was rendering, and a screenshot cannot say whether the
  -- pane chose it or the trim ate it.
  snapshot(ready(3, 5))
  local drawn = joined(render())
  has("ready footer offers movement", drawn, "j/k")
  has("ready footer offers send", drawn, "send")

  snapshot({ state = "pending" })
  local pending = joined(render())
  hasnt("pending footer does not offer movement", pending, "j/k")
  has("pending footer offers refresh", pending, "refresh")
end

print("== usable while the body is still being read ==")
do
  -- 40 files is more than one `LINES_PER_FRAME` bite, so the first render
  -- returns with the parse unfinished — which is the state this asserts about.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  local before = diff.LINES_PER_FRAME
  diff.LINES_PER_FRAME = 200 -- a small bite, so one frame cannot finish it

  snapshot(ready(40, 60))
  local first = render()
  local drawn = joined(first)

  has("it says it is still reading", drawn, "reading")
  check("the body is already a surface with rows", (surface_cells(first) or {})[1] ~= nil)

  -- The claim: the file list is the KERNEL's, so it is whole while the body is
  -- part-read. Files 30 and 40 are far past what a 200-line bite has reached.
  has("the list knows a file the parse has not reached", drawn, "file30.txt")
  has("the list knows the last file", drawn, "file40.txt")

  -- Every row the list DRAWS is a click target — including the ones the parse
  -- has not reached. The list is windowed to the pane's height, so this is a
  -- count of what is on screen and not of the whole diff; asserting 40 here was
  -- asserting that a 40-row pane draws 40 rows plus its directory headers.
  local shown = 0
  for _, line in ipairs(texts(first)) do
    if line:match("[MADR] file%d+%.txt") then
      shown = shown + 1
    end
  end
  check("some rows are on screen", shown > 10, "only " .. shown)
  eq("every row on screen is a click target", #file_ids(first), shown)

  local targets = {}
  for _, id in ipairs(file_ids(first)) do
    targets[id] = true
  end
  check("including one past the parse", targets["file:pkg/file30.txt"] == true)

  -- And the footer is the working one: a part-read diff is still navigable.
  has("the keys are offered while reading", drawn, "j/k")

  -- A click on a file the parse has not reached is DEFERRED, not dropped: the
  -- frame that reaches the file is the frame that lands on it. The first
  -- version made those rows inert instead, which is honest and useless.
  check(
    "clicking an unreached file is accepted",
    plugin.on_click({ id = "file:pkg/file30.txt", role = "row" })
  )
  -- Asserted on the SELECTED body line, not on the file list (which names every
  -- file whether or not the cursor is there) and not by re-parsing here.
  --
  -- Calling `diff.parse` from the test to check the row index is what NOT to do:
  -- the epoch is the plugin's, so guessing it forks the cache and the two parses
  -- restart each other forever, and nothing ever finishes. The pane's own output
  -- is the oracle.
  local landed = false
  for _ = 1, 400 do
    if (selected_line(render()) or ""):find("file30.txt", 1, true) then
      landed = true
      break
    end
  end
  check("and lands there once the parse reaches it", landed)

  diff.LINES_PER_FRAME = before
  diff.forget("s1")
end

print("== truncation names what is missing ==")
do
  snapshot(ready(2, 5, { truncated = true, raw_bytes = 21 * 1024 * 1024 }))
  has("it says the size that was cut", joined(render()), "4.0 of 21.0 MB")

  snapshot(ready(2, 5, { truncated = true }))
  has("and degrades without raw_bytes", joined(render()), "some changes are not shown")
end

print("== the list and the body are two lists now ==")
do
  -- Since the kernel began deriving `files` from `--numstat` rather than from
  -- the body, a capped diff lists files whose patch is not there. Index `n` in
  -- one is not index `n` in the other, and the pane has to survive that.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")

  local entry = ready(3, 5)
  -- Three files listed; the body carries only the first two, as a cut would
  -- leave it. Deliberately listed OUT of the body's order too, so an index join
  -- would land on the wrong file rather than merely fail.
  entry.body = body_of(2, 5)
  entry.files = {
    { path = "pkg/file3.txt", added = 5, removed = 5, status = "M" },
    { path = "pkg/file1.txt", added = 5, removed = 5, status = "M" },
    { path = "pkg/file2.txt", added = 5, removed = 5, status = "A" },
  }
  entry.truncated = true
  entry.raw_bytes = 9 * 1024 * 1024
  snapshot(entry)

  local tree = render()
  local drawn = joined(tree)
  has("every listed file is shown", drawn, "file3.txt")
  has("the banner counts files, not only bytes", drawn, "2 of 3 changed files are shown")

  local targets = {}
  for _, id in ipairs(file_ids(tree)) do
    targets[id] = true
  end
  check("a file the body carries is clickable", targets["file:pkg/file1.txt"] == true)
  check("a file it does not carry is not", targets["file:pkg/file3.txt"] ~= true)

  -- The join that matters: clicking the SECOND row must reach the file that row
  -- names, not the second file of the body.
  check("clicking is by path", plugin.on_click({ id = "file:pkg/file2.txt", role = "row" }))
  has("and lands on the file that was named", selected_line(render()) or "", "file2.txt")

  diff.forget("s1")
end

print("== the list has a cursor of its own ==")
do
  -- The kernel lists every changed file and caps only the patch, so a large diff
  -- names files the body has no rows for. Before the list had a cursor, `tab`
  -- walked the BODY's file rows and those files were unreachable by any key.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")

  local entry = ready(3, 5)
  entry.body = body_of(1, 5) -- only file1's patch survived the cut
  entry.files = {
    { path = "pkg/file1.txt", added = 5, removed = 5, status = "M" },
    { path = "pkg/file2.txt", added = 5, removed = 5, status = "M" },
    { path = "pkg/file3.txt", added = 5, removed = 5, status = "A" },
  }
  entry.truncated = true
  snapshot(entry)
  render() -- settle the parse

  --- Where the list is pointing when it is NOT simply following the body.
  ---
  --- Read from `state`, which is where the pane keeps it, and rendered first so
  --- the assertions run against a pane that has drawn what it decided.
  local function highlighted()
    render()
    return state_backing["list:s1" .. DEFAULT_SCOPE]
  end

  eq("it starts following the body", highlighted(), nil)

  check("tab moves on", plugin.on_action("review.next_file"))
  eq("onto a file the body does not carry", highlighted(), "pkg/file2.txt")
  check("and again", plugin.on_action("review.next_file"))
  eq("to the last listed file", highlighted(), "pkg/file3.txt")
  check("and stops at the end", plugin.on_action("review.next_file"))
  eq("rather than wrapping", highlighted(), "pkg/file3.txt")

  -- The property that keeps this from becoming a second thing to track: ANY
  -- movement of the body puts the list back in step with it.
  check("moving the body", plugin.on_action("review.next"))
  eq("puts the list back to following", highlighted(), nil)

  -- And a file the body DOES carry moves both, so they never disagree by accident.
  plugin.on_action("review.previous_file")
  eq("stepping back onto a covered file follows the body", highlighted(), nil)

  -- Marking follows the list, so a file with no patch can still be ticked off.
  plugin.on_action("review.next_file")
  eq("the list is on the uncovered file", highlighted(), "pkg/file2.txt")
  plugin.on_action("review.mark")
  local marks = state_backing["marks:s1"] or {}
  check("and marking it works", marks["pkg/file2.txt"] == true)
  has("the tick is drawn", joined(render()), "✓")

  diff.forget("s1")
end

print("== side by side ==")
do
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  snapshot(ready(2, 6))
  render()

  local before = surface_cells(render()) or {}
  check("unified draws rows", #before > 0)

  check("v switches layout", plugin.on_action("review.side"))
  local tree = render()
  local after = surface_cells(tree) or {}

  -- The claim D2 is tested by: two columns of cells, one selectable row across
  -- both, and no new node kind to do it.
  local used = kinds(tree)
  for kind in pairs(used) do
    check("still one of the four: " .. kind, ({
      text = true,
      box = true,
      input = true,
      surface = true,
    })[kind] ~= nil)
  end

  -- A paired body row carries the divider, which is what makes it two columns.
  local divided = 0
  for _, line in ipairs(after) do
    for _, run in ipairs(line) do
      if run.text == "│" then
        divided = divided + 1
      end
    end
  end
  check("paired rows are split by a divider", divided > 0, "found " .. divided)

  -- Every line is the SAME width — measured against each other rather than
  -- against a number, since the body's width is what the changed-files list
  -- leaves it. A half that did not pad would walk the divider down the screen.
  local ragged, want = nil, nil
  for index, line in ipairs(after) do
    local total = 0
    for _, run in ipairs(line) do
      total = total + rows_len(run.text)
    end
    want = want or total
    if total ~= want then
      ragged = ragged or ("line " .. index .. " measures " .. total .. ", not " .. want)
    end
  end
  check("every paired line is the same width", ragged == nil, ragged)

  -- Merging means fewer rows, which means `j` moves once per PAIR — the rule.
  check("the paired body is shorter", #after < #before, #after .. " vs " .. #before)

  check("v switches back", plugin.on_action("review.side"))
  eq("and the layout is unified again", #(surface_cells(render()) or {}), #before)

  diff.forget("s1")
end

print("== the body is clickable, without a fifth node kind ==")
do
  -- The question side-by-side was meant to settle: does a dense pane need a node
  -- kind with per-line identity? It does not. A `surface` takes an `id` like any
  -- node, the kernel records its rect, and a click arrives with coordinates
  -- inside it — which the plugin can resolve because it decided the geometry.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  snapshot(ready(3, 6))
  render()
  plugin.on_action("review.top")

  local body
  walk(render(), function(item)
    if item.type == "surface" then
      body = item
    end
  end)
  eq("the surface carries identity", body and body.id, "body")

  -- Click ten lines down and the cursor lands on whatever was drawn there.
  local before = selected_line(render())
  check("clicking the body is handled", plugin.on_click({ id = "body", x = 4, y = 10 }))
  local after = selected_line(render())
  check("and the selection moved", before ~= after, tostring(before) .. " -> " .. tostring(after))

  -- A click past the drawn rows is declined rather than guessed at.
  check(
    "a click below the content is declined",
    plugin.on_click({ id = "body", x = 0, y = 9999 }) == false
  )

  diff.forget("s1")
end

print("== folding ==")
do
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  snapshot(ready(3, 5))
  render()
  plugin.on_action("review.top")

  local function body_lines()
    return #(surface_cells(render()) or {})
  end
  --- The BODY's header row for a file, told apart from the file list's row for
  --- the same path by the fold chevron only the body draws.
  ---
  --- Plain finds, not `[▸▾]`: a Lua character class is a set of BYTES, so a
  --- class of multi-byte characters matches their bytes individually and means
  --- nothing. It silently matched no header at all, and the failures read as
  --- folding being broken while every count around them said it worked.
  local function header_of(path)
    for _, line in ipairs(body_texts(render())) do
      local chevron = line:find("▸", 1, true) or line:find("▾", 1, true)
      if chevron and line:find(path, 1, true) then
        return line
      end
    end
    return nil
  end

  local whole = body_lines()
  check("the body has rows", whole > 6)
  check(
    "an unfolded file shows ▾",
    (header_of("pkg/file1.txt") or ""):find("▾", 1, true) ~= nil
  )

  -- `enter` folds the file the cursor is on.
  check("enter folds", plugin.on_action("review.find_commit"))
  local after = body_lines()
  check("the body is shorter", after < whole, after .. " vs " .. whole)
  check("and the header says so", (header_of("pkg/file1.txt") or ""):find("▸", 1, true) ~= nil)
  check("the file is still listed", joined(render()):find("file1.txt", 1, true) ~= nil)

  check("enter unfolds", plugin.on_action("review.find_commit"))
  eq("back to the whole body", body_lines(), whole)

  -- v1's rule: `reviewed XOR override`. Marking folds; the override then lets
  -- you peek into a marked file WITHOUT unmarking it, which is the whole reason
  -- two sets exist instead of one.
  check("marking it", plugin.on_action("review.mark"))
  local marked = header_of("pkg/file1.txt") or ""
  check("shows the tick", marked:find("✓", 1, true) ~= nil)
  check("and folds it", marked:find("▸", 1, true) ~= nil)
  check("shortening the body", body_lines() < whole)

  check("peeking into it", plugin.on_action("review.find_commit"))
  local peeked = header_of("pkg/file1.txt") or ""
  check("keeps the tick", peeked:find("✓", 1, true) ~= nil, peeked)
  check("while unfolding", peeked:find("▾", 1, true) ~= nil, peeked)
  eq("with the whole body back", body_lines(), whole)

  -- Folding composes with the layout rather than being a third view.
  plugin.on_action("review.find_commit") -- fold again
  local folded_unified = body_lines()
  plugin.on_action("review.side")
  local folded_side = body_lines()
  check(
    "still folded side by side",
    folded_side <= folded_unified + 1,
    folded_side .. " vs " .. folded_unified
  )
  check(
    "and file1 is still collapsed",
    (header_of("pkg/file1.txt") or ""):find("▸", 1, true) ~= nil
  )
  plugin.on_action("review.side")

  diff.forget("s1")
end

print("== every view toggle is advertised ==")
do
  -- The guard for what went wrong when `v` was added: `w` was replaced in the
  -- footer rather than joined by it, so wrapping worked and nothing on screen
  -- said so. Nothing failed — the key was declared, F1 listed it, `plugin check`
  -- passed — which is exactly why this needs a test rather than care.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  snapshot(ready(2, 4))
  local drawn = joined(render())

  local declared = {}
  for _, entry in ipairs(plugin.keys) do
    declared[entry.key] = entry.action
  end

  for _, pair in ipairs({
    { "w", "review.wrap", "wrap" },
    { "v", "review.side", "split" },
    { "↵", "review.find_commit", "fold" },
    { "m", "review.mark", "seen" },
    { "r", "review.refresh", "refresh" },
    { "e", "review.send", "send" },
    { "/", "review.find", "find" },
  }) do
    local key, action, label = pair[1], pair[2], pair[3]
    -- `↵` is `enter` in the keys table and a glyph in the footer.
    local declared_as = key == "↵" and "enter" or key
    eq("`" .. key .. "` is declared", declared[declared_as], action)
    check("and offered in the footer as '" .. label .. "'", drawn:find(label, 1, true) ~= nil)
  end
  diff.forget("s1")
end

print("== the way out is the pane that shares the slot ==")
do
  -- v1's review is a tab of the centre pane, so leaving it shows the terminal
  -- again. `command("focus", { toggle = true })` returns to wherever focus came
  -- from instead — which is the session list, if that is where the key was
  -- pressed. This asserts the v1 answer, from BOTH starting points.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")

  local function focused_now()
    local last = commands[#commands]
    return last and last.kind == "focus" and last.args and last.args.text or nil
  end

  -- From the agent: the key opens the review.
  focused_pane = "agent"
  snapshot(ready(2, 3))
  plugin.on_action("review.open")
  eq("opens onto itself", focused_now(), "review")

  -- Focused: the same key leaves, onto the slot's other occupant.
  focused_pane = "review"
  snapshot(ready(2, 3))
  plugin.on_action("review.open")
  eq("leaves onto the agent", focused_now(), "agent")
  check("and does not ask the kernel to toggle", commands[#commands].args.toggle == nil)

  -- The case that prompted this: opened FROM THE SESSION LIST, the way out is
  -- still the agent and not the list.
  focused_pane = "sessions"
  snapshot(ready(2, 3))
  plugin.on_action("review.open")
  eq("opens from the list too", focused_now(), "review")
  focused_pane = "review"
  snapshot(ready(2, 3))
  plugin.on_action("review.open")
  eq("and still leaves onto the agent", focused_now(), "agent")

  -- `esc` and a send leave the same way, so the exits cannot disagree.
  plugin.on_action("review.close")
  eq("esc leaves onto the agent", focused_now(), "agent")
  plugin.on_action("review.send")
  eq("send leaves onto the agent", focused_now(), "agent")

  -- A disabled sibling is not a destination.
  thurbox.plugins = {
    { name = "agent", slot = "center", kind = "pane", state = "disabled" },
    { name = "review", slot = "center", kind = "pane", state = "visible" },
  }
  plugin.on_action("review.close")
  eq("with no one to land on, it asks the kernel", focused_now(), "review")
  check("by toggling", commands[#commands].args.toggle == true)

  focused_pane = "agent"
  diff.forget("s1")
end

print("== the session-column toggle is on the border ==")
do
  -- v1 paints the collapse chevron on the left of the CENTRAL pane's top border,
  -- on every central view. This pane replaces the agent in that slot, so without
  -- it `F9` and its arrow vanish from the screen for as long as you read a diff.
  local diff = require("thurbox-code-review.lib.diff")
  diff.forget("s1")
  snapshot(ready(2, 3))

  --- Every node carrying a click verb, with the text it draws.
  local function verbs(node)
    local out = {}
    walk(node, function(item)
      if item.role and item.role:match("^action:") then
        local parts = {}
        for _, line in ipairs(type(item.text) == "table" and item.text or {}) do
          for _, run in ipairs(line) do
            parts[#parts + 1] = run.text or ""
          end
        end
        out[#out + 1] = { role = item.role, text = table.concat(parts), len = item.len }
      end
    end)
    return out
  end

  local found = verbs(render())
  check("the chevron carries a click verb", #found >= 1, "found " .. #found)
  for _, hit in ipairs(found) do
    eq("and it is the session toggle", hit.role, "action:sessions.toggle_panel")
    check("with an exact width, so the geometry is unchanged", hit.len ~= nil)
  end
  -- Two runs, ONE target: the chevron reads accent and the hint muted, but both
  -- carry the same verb so the kernel hit-tests them as one button. Split
  -- differently, the hint is inert and the label feels like it has a hole.
  eq("chevron and hint are both targets", #found, 2)

  local drawn = joined(render())
  check("the arrow points the way the list will move", drawn:find("◀", 1, true) ~= nil)
  check("and the chord is named", drawn:find("F9", 1, true) ~= nil)

  -- Collapsed, it points the other way.
  store_backing["panels.sessions"] = false
  check("collapsed, it points back", joined(render()):find("▶", 1, true) ~= nil)
  store_backing["panels.sessions"] = nil

  -- Narrow: the hint goes before the chevron does, and below the floor both do.
  local narrow = joined(render({ width = 30, height = 20, focused = true, elapsed = 0 }))
  check("a narrow pane keeps the arrow", narrow:find("◀", 1, true) ~= nil)
  check("but drops the chord", narrow:find("F9", 1, true) == nil)

  diff.forget("s1")
end

print("== notes ==")
do
  local diff = require("thurbox-code-review.lib.diff")
  local notes = require("thurbox-code-review.lib.notes")
  diff.forget("s1")
  forget("s1")
  snapshot(ready(2, 4))
  render()
  plugin.on_action("review.top")

  local function composing_now()
    return state_backing["compose:s1"] ~= nil
  end

  --- Type a string into the compose field, one key at a time, as a keyboard
  --- does — through `on_key`, which is the only route a character has.
  local function type_in(text)
    for _, ch in utf8.codes(text) do
      plugin.on_key({ char = utf8.char(ch), key = utf8.char(ch) })
    end
  end

  -- Move onto a body line, then note it.
  plugin.on_action("review.next")
  plugin.on_action("review.next")
  check("c opens the composer", plugin.on_action("review.comment"))
  has("which says what is being noted", joined(render()), "note on")
  has("and how long it lasts, where you are typing", joined(render()), "lost when thurbox quits")

  -- The fourth node kind, finally used.
  local used = kinds(render())
  check("the field is an `input` node", used.input == true)

  type_in("this looks wrong")
  check("⇥ cycles the classification", plugin.on_action("review.next_file"))
  check("↵ saves", plugin.on_action("review.find_commit"))

  local written = notes.all(state, "s1")
  eq("one note", #written, 1)
  eq("with the text typed", written[1].text, "this looks wrong")
  eq("and the cycled class", written[1].class, "praise")
  eq("anchored to a line", written[1].kind, "line")
  check("of a file in the diff", written[1].path ~= nil)

  -- It is a row in the body, selectable like any other.
  local body = body_texts(render())
  local shown = nil
  for _, line in ipairs(body) do
    if line:find("this looks wrong", 1, true) then
      shown = line
    end
  end
  check("the note is drawn in the body", shown ~= nil)
  has("badged with its class", shown or "", "[Praise]")

  -- `↵` on a note edits it rather than folding.
  local at = nil
  for index, line in ipairs(body) do
    if line:find("this looks wrong", 1, true) then
      at = index
    end
  end
  check("found the row", at ~= nil)
  state_backing["sel:s1" .. DEFAULT_SCOPE] = nil
  for _ = 1, at - 1 do
    plugin.on_action("review.next")
  end
  check("↵ on a note opens it for editing", plugin.on_action("review.find_commit"))
  has("with the compose strip saying so", joined(render()), "editing note on")
  type_in("!")
  plugin.on_action("review.find_commit")
  eq("still one note", #notes.all(state, "s1"), 1)
  eq("with the edit applied", notes.all(state, "s1")[1].text, "this looks wrong!")

  -- A summary note anchors to the review, not a file.
  check("s opens a summary", plugin.on_action("review.summary"))
  type_in("overall fine")
  plugin.on_action("review.find_commit")
  local all = notes.all(state, "s1")
  eq("two notes now", #all, 2)
  eq("the second is on the review", all[2].kind, "review")

  -- Sending: v1's shape, and the notes ARE the review.
  -- Cleared so the send below is the last command, not one of many.
  for index = #commands, 1, -1 do
    commands[index] = nil
  end
  plugin.on_action("review.send")
  local sent = nil
  for _, entry in ipairs(commands) do
    if entry.kind == "send" then
      sent = entry.args.text
    end
  end
  check("a send was issued", sent ~= nil)
  has("addressed to the agent", sent or "", "Please address the following code review")
  has("headed as v1 heads it", sent or "", "# Code review")
  has("grouped under the file", sent or "", "## pkg/file")
  -- `old:` and not `new:`: the cursor was on a DELETION, which has only an old
  -- side, and `anchor_for` gives it that one. Asserting `new:` here passed for
  -- the wrong reason on a fixture whose first body row happened to be an
  -- addition.
  has("with the badge and the location", sent or "", "- **[Praise]** (old:")
  has("carrying the note", sent or "", "this looks wrong!")
  has("and a summary section", sent or "", "## Summary")
  has("with the summary note", sent or "", "overall fine")

  -- Cancelling leaves nothing behind.
  plugin.on_action("review.comment")
  type_in("never mind")
  plugin.on_action("review.close")
  eq("esc discards", #notes.all(state, "s1"), 2)

  -- `x` deletes the note under the cursor.
  state_backing["sel:s1" .. DEFAULT_SCOPE] = nil
  local rows_now = body_texts(render())
  local note_at = nil
  for index, line in ipairs(rows_now) do
    if line:find("this looks wrong!", 1, true) then
      note_at = index
    end
  end
  for _ = 1, (note_at or 1) - 1 do
    plugin.on_action("review.next")
  end
  check("x deletes", plugin.on_action("review.delete"))
  eq("one note left", #notes.all(state, "s1"), 1)
  eq("and it is the summary", notes.all(state, "s1")[1].kind, "review")

  -- With a file MARKED, which folds it — the state the render proof reaches by
  -- the time it writes a note, and the one where the note vanished.
  forget("s1")
  render()
  plugin.on_action("review.top")
  plugin.on_action("review.mark")
  local marked_path = nil
  for path in pairs(state_backing["marks:s1"] or {}) do
    marked_path = path
  end
  check("a file is marked", marked_path ~= nil)
  plugin.on_action("review.comment")
  check("the composer opens on a marked file", composing_now())
  type_in("noted on a folded file")
  plugin.on_action("review.find_commit")
  eq("the note saves", #notes.all(state, "s1"), 1)
  local seen = false
  for _, line in ipairs(body_texts(render())) do
    if line:find("noted on a folded file", 1, true) then
      seen = true
    end
  end
  -- Saving a note unfolds the file it is on, so the note you just wrote is
  -- visible. Without that, `m` (which folds) followed by `c` saved the note and
  -- hid it in the same breath.
  check("and is drawn, because saving unfolded the file", seen)
  check("while the file stays marked seen", (state_backing["marks:s1"] or {})[marked_path] == true)

  -- The cache bug this block exists for, isolated from the unfold above: fold a
  -- DIFFERENT file, then note one that was never folded. The fold filter runs
  -- over the list the notes were interleaved into, so a signature that does not
  -- name the notes serves a list built before the note existed — and the note
  -- saves, exports, and is invisible.
  forget("s1")
  render()
  plugin.on_action("review.top")
  plugin.on_action("review.next_file") -- onto the SECOND file
  plugin.on_action("review.mark") -- fold that one
  plugin.on_action("review.previous_file") -- back to the first, unfolded
  plugin.on_action("review.comment")
  type_in("on an unfolded file, with another folded")
  plugin.on_action("review.find_commit")
  local drawn = false
  for _, line in ipairs(body_texts(render())) do
    if line:find("on an unfolded file", 1, true) then
      drawn = true
    end
  end
  check("a note shows even when another file is folded", drawn)

  -- A note on a LINE sits directly under that line, which is the whole point of
  -- anchoring one — and it has to stay there when the layout changes, because
  -- the row it attaches to is a different row in the paired list. The join is by
  -- (path, side, number), so it survives; asserted rather than assumed.
  forget("s1")
  render()
  plugin.on_action("review.top")
  for _ = 1, 3 do
    plugin.on_action("review.next") -- onto a body line
  end
  plugin.on_action("review.comment")
  type_in("right under this line")
  plugin.on_action("review.find_commit")

  --- The body line before the note, in whatever layout is on.
  local function line_above_note()
    local body, previous = body_texts(render()), nil
    for _, text in ipairs(body) do
      if text:find("right under this line", 1, true) then
        return previous
      end
      previous = text
    end
    return nil
  end

  local unified_above = line_above_note()
  check("the note has a line above it", unified_above ~= nil)
  check(
    "which is a body line, not a header",
    (unified_above or ""):find("old line", 1, true) ~= nil,
    tostring(unified_above)
  )

  plugin.on_action("review.side")
  local side_above = line_above_note()
  check(
    "side by side, it is still under a line",
    (side_above or ""):find("old line", 1, true) ~= nil,
    tostring(side_above)
  )
  plugin.on_action("review.side")

  -- A SUMMARY note belongs to no file, so the fold filter has to keep it when
  -- anything is folded — which is the state a reviewer is most likely to be
  -- writing one in.
  forget("s1")
  render()
  plugin.on_action("review.top")
  plugin.on_action("review.mark") -- fold something
  plugin.on_action("review.summary")
  type_in("overall this is fine")
  plugin.on_action("review.find_commit")
  local summary_shown = false
  for _, line in ipairs(body_texts(render())) do
    if line:find("overall this is fine", 1, true) then
      summary_shown = true
    end
  end
  check("a summary survives a folded diff", summary_shown)

  -- With a search still open, which is the state the render proof reaches by the
  -- time it writes one — and the state that showed the note never saving.
  forget("s1")
  plugin.on_action("review.find")
  for _, ch in utf8.codes("greet") do
    plugin.on_key({ char = utf8.char(ch), key = utf8.char(ch) })
  end
  plugin.on_action("review.find_commit") -- commit the query, bar stays open
  plugin.on_action("review.comment")
  check("the composer opens with a search open", composing_now())
  type_in("noted while searching")
  plugin.on_action("review.find_commit")
  eq("and the note saves", #notes.all(state, "s1"), 1)

  forget("s1")
  diff.forget("s1")
end

-- ── the target picker ───────────────────────────────────────────────────────

print("== untrusted, the pane still works and the picker says why ==")
do
  forget("s1")
  forget_runs()
  grant_run(false)
  snapshot(ready(2, 3))
  render()

  -- The property worth protecting: nothing is run, and nothing needs to be, for
  -- the diff the kernel already computes.
  eq("nothing was run for the kernel's own diff", programs_asked(), "")
  has("and the header names its range", joined(render()), "main..HEAD")

  check("t opens the picker", plugin.on_action("review.target"))
  local shown = joined(render())
  has("it asks what to review", shown, "Review what?")
  has("working changes are offered", shown, "uncommitted changes")
  has("so is the branch", shown, "main..HEAD")
  -- The branch IS the kernel's here, so it is the one that costs nothing.
  has("and is marked as already served", shown, "ready")
  -- And it is the one in force, marked. `nil` means "the kernel's own", which is
  -- the BRANCH here — a dot that matched nothing left the picker unable to say
  -- what you were already looking at.
  has("the target in force is marked", shown, "● main..HEAD")
  hasnt("and it is not the other one", shown, "● uncommitted")
  has("the rest needs trust", shown, "needs trust")

  -- `t` opens ON the row in force, so `t ↵` changes nothing — which is what
  -- makes `t` safe to press just to find out what you are looking at.
  plugin.on_action("review.find_commit")
  hasnt("↵ on the row it opened on is a no-op", joined(render()), "Review what?")
  has("and the target did not move", joined(render()), "main..HEAD")
  plugin.on_action("review.target")

  -- Choosing one that needs trust does NOT switch to it: it would fail, and a
  -- picker that lets you pick a broken thing is worse than one that says so.
  plugin.on_action("review.top")
  check("↵ on an untrusted choice is declined", plugin.on_action("review.find_commit"))
  has("so the picker stays open", joined(render()), "Review what?")

  check("esc closes it", plugin.on_action("review.close"))
  hasnt("and the diff is back", joined(render()), "Review what?")
  eq("still nothing was run", programs_asked(), "")
end

print("== trusted, a commit can be reviewed ==")
do
  forget("s1")
  forget_runs()
  grant_run(true)
  snapshot(ready(2, 3))
  render()

  check("t opens the picker", plugin.on_action("review.target"))
  render()
  -- Opening it is what asks for the commit list, and not before.
  has("the picker asks git for the log", programs_asked(), " log --no-color")
  has("bounded", programs_asked(), "-n 200")
  has("over the branch's range", programs_asked(), "main..HEAD")
  has("with paths left verbatim", programs_asked(), "core.quotepath=false")
  has("and it says it is asking", joined(render()), "listing commits")

  answers("rv:s1:log", {
    state = "done",
    ok = true,
    truncated = false,
    stdout = "a1b2c3d\t9999999\tmake it work\ne4f5a6b\t8888888 7777777\tmerge branch\n",
  })
  local listed = joined(render())
  has("the commit is offered", listed, "a1b2c3d make it work")
  has("with its subject", listed, "make it work")
  -- `git show` draws nothing for a merge without `-m`, so the picker says which
  -- ones those are rather than offering a silently empty diff.
  has("and a merge is labelled", listed, "merge")

  -- Down past working and branch, onto the first commit.
  plugin.on_action("review.top")
  plugin.on_action("review.next")
  plugin.on_action("review.next")
  check("↵ picks it", plugin.on_action("review.find_commit"))
  hasnt("the picker closes", joined(render()), "Review what?")

  local head = joined(render())
  has("and the header names the commit", head, "a1b2c3d make it work")
  hasnt("not the branch it is on", head, "main..HEAD")

  -- The two runs a commit target needs, with v1's own flags.
  local wanted = programs_asked()
  has("git show for the patch", wanted, "show --no-color --format= 'a1b2c3d'")
  has("and one command for the file list", wanted, "--numstat --raw -M -z")
  has("with the sha quoted", wanted, "'a1b2c3d'")

  has("meanwhile it says it is building", joined(render()), "Building diff")

  answers("rv:s1:commit:a1b2c3d:files", {
    state = "done",
    ok = true,
    truncated = false,
    stdout = ":100644 100644 aaa bbb M\0src/one.lua\0" .. "3\t1\tsrc/one.lua\0",
  })
  answers("rv:s1:commit:a1b2c3d:body", {
    state = "done",
    ok = true,
    truncated = false,
    stdout = table.concat({
      "diff --git a/src/one.lua b/src/one.lua",
      "--- a/src/one.lua",
      "+++ b/src/one.lua",
      "@@ -1,2 +1,4 @@",
      " local x = 1",
      "-local y = 2",
      "+local y = 3",
      "+local z = 4",
      "+local w = 5",
      "",
    }, "\n"),
  })
  render()
  local drawn = joined(render())
  -- The list is a TREE: the directory is its own row and the file row carries
  -- the leaf. Asserting on the joined path here would assert the list is flat.
  has("the commit's directory is listed", drawn, "src/")
  has("with its file under it", drawn, "one.lua")
  has("with its counts", drawn, "+3 -1")
  local lines = table.concat(body_texts(render()), "\n")
  has("and its body is the run's", lines, "local z = 4")
  hasnt("not the kernel's", lines, "new line 1 of file 1")

  -- Back to the branch, which is the kernel's and costs nothing.
  plugin.on_action("review.target")
  plugin.on_action("review.top") -- working changes, which need a run
  plugin.on_action("review.next") -- the branch, which is the kernel's
  plugin.on_action("review.find_commit")
  local back = joined(render())
  -- A tree again: `pkg/` heads the group and the leaf is the row.
  has("switching back reaches the kernel's diff", back, "file1.txt")
  has("and the header says so", back, "main..HEAD")
end

print("== the two sources report their own limits ==")
do
  forget("s1")
  forget_runs()
  grant_run(true)
  snapshot(ready(2, 3))
  render()

  target_lib.set(state, "s1", { kind = "commit", sha = "beefbee" })
  answers("rv:s1:commit:beefbee:files", {
    state = "done",
    ok = true,
    truncated = false,
    stdout = ":100644 100644 aaa bbb M\0src/big.lua\0" .. "9\t0\tsrc/big.lua\0",
  })
  answers("rv:s1:commit:beefbee:body", {
    state = "done",
    ok = true,
    -- Cut by the RUN's cap, which is 256 KB and not the kernel's 4 MB.
    truncated = true,
    stdout = table.concat({
      "diff --git a/src/big.lua b/src/big.lua",
      "--- a/src/big.lua",
      "+++ b/src/big.lua",
      "@@ -1,1 +1,3 @@",
      "+one",
      "+tw",
    }, "\n"),
  })
  render()
  local said = joined(render())
  has("the banner names the cap that applied", said, "256 KB")
  hasnt("not the kernel's", said, "4.0 of")

  -- git failing is git's own words, not a shrug.
  target_lib.set(state, "s1", { kind = "commit", sha = "0badc0d" })
  answers("rv:s1:commit:0badc0d:files", {
    state = "done",
    ok = false,
    status = 128,
    stderr = "fatal: bad object 0badc0d\n",
  })
  answers("rv:s1:commit:0badc0d:body", { state = "done", ok = false, status = 128, stderr = "" })
  local failed = joined(render())
  has("a failed run says why", failed, "fatal: bad object 0badc0d")
  has("and offers the way out", failed, "press r to try again")

  target_lib.set(state, "s1", nil)
  grant_run(false)
  forget_runs()
  forget("s1")
end

print("== where you are is per target ==")
do
  forget("s1")
  forget_runs()
  grant_run(true)
  snapshot(ready(3, 6))
  render()

  for _ = 1, 8 do
    plugin.on_action("review.next")
  end
  local moved = state_backing["sel:s1" .. DEFAULT_SCOPE]
  check("the cursor moved on the branch", (moved or 1) > 1)

  target_lib.set(state, "s1", { kind = "commit", sha = "abc1234" })
  render()
  eq(
    "and the commit starts at the top",
    state_backing["sel:s1" .. target_lib.scope("", { kind = "commit", sha = "abc1234" })],
    nil
  )

  target_lib.set(state, "s1", nil)
  render()
  eq("while the branch kept its place", state_backing["sel:s1" .. DEFAULT_SCOPE], moved)

  grant_run(false)
  forget_runs()
  forget("s1")
end

print("== no session ==")
do
  _G.thurbox = {
    sessions = {},
    diffs = {},
    theme = { name = "t", roles = roles },
    registry = {
      settings = settings,
      keys = { { action = "sessions.toggle_panel", key = "f9", plugin = "sessions" } },
    },
  }
  store_backing.selected = nil
  has("it says so", joined(render()), "No session selected")
end

print(string.format("\n%d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
