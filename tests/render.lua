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

local commands = {}
_G.command = function(kind, args)
  commands[#commands + 1] = { kind = kind, args = args }
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

local function snapshot(diff)
  _G.thurbox = {
    sessions = { SESSION },
    diffs = diff and { s1 = diff } or {},
    theme = { name = "test", roles = roles },
    registry = { settings = {}, keys = {} },
    settings = {},
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

local function ids(node)
  local out = {}
  walk(node, function(item)
    if item.id then
      out[#out + 1] = item.id
    end
  end)
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
  local found = ids(render())
  eq("one id per file", #found, 3)
  eq("named by index", found[1], "file:1")
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
  eq("every row on screen is a click target", #ids(first), shown)

  local targets = {}
  for _, id in ipairs(ids(first)) do
    targets[id] = true
  end
  check("including one past the parse", targets["file:30"] == true)

  -- And the footer is the working one: a part-read diff is still navigable.
  has("the keys are offered while reading", drawn, "j/k")

  -- A click on a file the parse has not reached is DEFERRED, not dropped: the
  -- frame that reaches the file is the frame that lands on it. The first
  -- version made those rows inert instead, which is honest and useless.
  check("clicking an unreached file is accepted", plugin.on_click({ id = "file:30", role = "row" }))
  -- Asserted on the BODY's last line, not on the file list (which names every
  -- file whether or not the cursor is there) and not by re-parsing here: the
  -- window puts the selection at the bottom, so the cursor arriving on file 30's
  -- header is that header becoming the last line the surface is handed.
  --
  -- Calling `diff.parse` from the test to check the row index is what NOT to do:
  -- the epoch is the plugin's, so guessing it forks the cache and the two parses
  -- restart each other forever, and nothing ever finishes. The pane's own output
  -- is the oracle.
  local landed = false
  for _ = 1, 400 do
    local body = surface_cells(render()) or {}
    local text = {}
    for _, run in ipairs(body[#body] or {}) do
      text[#text + 1] = run.text or ""
    end
    if table.concat(text):find("file30.txt", 1, true) then
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
  local drawn = joined(render())
  has("it says how much is shown", drawn, "4.0 MB of 21.0 MB")

  snapshot(ready(2, 5, { truncated = true }))
  has("and degrades without raw_bytes", joined(render()), "some changes are not shown")
end

print("== no session ==")
do
  _G.thurbox = {
    sessions = {},
    diffs = {},
    theme = { name = "t", roles = roles },
    registry = { settings = {}, keys = {} },
  }
  store_backing.selected = nil
  has("it says so", joined(render()), "No session selected")
end

print(string.format("\n%d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
