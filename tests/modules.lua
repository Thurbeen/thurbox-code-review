-- Exercises the pure modules of thurbox-code-review outside the plugin VM.
--
-- `lib.theme` and `lib.widgets` are the REAL bundled ones from the thurbox
-- checkout, so measurement and truncation behave as they do in the pane; only
-- the `thurbox` snapshot is faked.
--
-- Run it through `tests/run.sh`, which sets REPO and UI.

local REPO = assert(os.getenv("REPO"), "REPO=")
local UI = assert(os.getenv("UI"), "UI=")

-- The snapshot the bundled lib reads.
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
_G.thurbox = { theme = { name = "test", roles = roles }, registry = { settings = {} } }

local real_require = require
local loaded = {}
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
  local chunk = assert(loadfile(path), "cannot load " .. path)
  local value = chunk()
  loaded[name] = value
  return value
end

local diff = require("thurbox-code-review.lib.diff")
local rows = require("thurbox-code-review.lib.rows")
local export = require("thurbox-code-review.lib.export")

-- ── tiny test runner ────────────────────────────────────────────────────────

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

-- ── fixtures ────────────────────────────────────────────────────────────────

local function lines_of(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  -- the trailing empty split
  if out[#out] == "" then
    table.remove(out)
  end
  return out
end

local SAMPLE = lines_of([[
diff --git a/src/one.lua b/src/one.lua
index 1111111..2222222 100644
--- a/src/one.lua
+++ b/src/one.lua
@@ -10,4 +10,5 @@ local function thing()
 context one
-gone
+new
+also new
 context two
diff --git a/src/two.rs b/src/two.rs
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/src/two.rs
@@ -0,0 +1,2 @@
+fn main() {}
+// end
diff --git a/old/name.txt b/new/name.txt
similarity index 90%
rename from old/name.txt
rename to new/name.txt
@@ -1 +1 @@
-before
+after
]])

print("== parser ==")
do
  local parse = diff.parse("s", SAMPLE, 0)
  check("finishes in one bite", parse.done)
  eq("three files", #parse.files, 3)
  eq("first path", parse.files[1].path, "src/one.lua")
  eq("first added", parse.files[1].added, 2)
  eq("first removed", parse.files[1].removed, 1)
  eq("second status", parse.files[2].status, "A")
  eq("third status", parse.files[3].status, "R")
  eq("third old path", parse.files[3].old_path, "old/name.txt")
  eq("third new path", parse.files[3].path, "new/name.txt")

  -- Line numbering: the first hunk starts at old 10 / new 10.
  local first_line
  for _, row in ipairs(parse.rows) do
    if row.kind == "line" then
      first_line = row
      break
    end
  end
  eq("first body line is context", first_line.side, "ctx")
  eq("first body old_no", first_line.old_no, 10)
  eq("first body new_no", first_line.new_no, 10)

  -- The addition after a deletion keeps the new-side counter moving and leaves
  -- the old side unnumbered.
  local adds = {}
  for _, row in ipairs(parse.rows) do
    if row.kind == "line" and row.side == "add" and row.file == 1 then
      adds[#adds + 1] = row
    end
  end
  eq("two additions in file one", #adds, 2)
  eq("first addition new_no", adds[1].new_no, 11)
  eq("first addition has no old_no", adds[1].old_no, nil)
  eq("second addition new_no", adds[2].new_no, 12)

  eq("hunk heading kept", parse.rows[2].heading, "local function thing()")
end

print("== the ---/+++ gate ==")
do
  -- A deleted line whose own content begins `-- ` arrives as `--- …`. Inside a
  -- hunk it must stay a deletion; the kernel's parser carries the same gate.
  local body = lines_of([[
diff --git a/x.lua b/x.lua
--- a/x.lua
+++ b/x.lua
@@ -1,2 +1,2 @@
--- a comment that looks like a header
++++ and one that looks like the other
]])
  local parse = diff.parse("gate", body, 0)
  eq("one file", #parse.files, 1)
  eq("one removal", parse.files[1].removed, 1)
  eq("one addition", parse.files[1].added, 1)
  local kept = {}
  for _, row in ipairs(parse.rows) do
    if row.kind == "line" then
      kept[#kept + 1] = row.side .. ":" .. row.text
    end
  end
  eq("deletion text survives", kept[1], "del:-- a comment that looks like a header")
  eq("addition text survives", kept[2], "add:+++ and one that looks like the other")
end

print("== one logical row is one selectable unit ==")
do
  local long = string.rep("x", 300)
  local body =
    lines_of("diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,1 +1,1 @@\n+" .. long)
  local parse = diff.parse("wrap", body, 0)
  local logical_lines = 0
  for _, row in ipairs(parse.rows) do
    if row.kind == "line" then
      logical_lines = logical_lines + 1
    end
  end
  eq("one logical body row", logical_lines, 1)

  local opts = {
    width = 40,
    height = 20,
    digits = rows.gutter_digits(parse),
    wrap = false,
    hscroll = 0,
    reviewed = {},
    selected = 3,
  }
  local unwrapped, map = rows.window(parse.rows, 1, opts)
  eq("unwrapped: one visual line per logical row", #unwrapped, #parse.rows)

  opts.wrap = true
  local wrapped, wmap = rows.window(parse.rows, 1, opts)
  check("wrapped: more visual lines", #wrapped > #unwrapped, #wrapped .. " vs " .. #unwrapped)

  -- Every visual line still names exactly one logical row, and the wrapped body
  -- line's several visual lines all name the SAME one.
  local seen = {}
  for _, at in ipairs(wmap) do
    seen[at] = (seen[at] or 0) + 1
  end
  eq("the body row occupies several visual lines", seen[3] > 1, true)
  eq("the file row still occupies one", seen[1], 1)
  check(
    "logical indices are non-decreasing",
    (function()
      for i = 2, #wmap do
        if wmap[i] < wmap[i - 1] then
          return false
        end
      end
      return true
    end)()
  )
  -- And unwrapped, index i maps to logical row i.
  for i = 1, #map do
    if map[i] ~= i then
      check("unwrapped map is the identity", false, "at " .. i)
      break
    end
  end
  check("unwrapped map is the identity", true)
end

print("== horizontal scroll pins the gutter ==")
do
  local body = lines_of(
    "diff --git a/h.txt b/h.txt\n--- a/h.txt\n+++ b/h.txt\n@@ -1,1 +1,1 @@\n+"
      .. string.rep("abcdefghij", 10)
  )
  local parse = diff.parse("h", body, 0)
  local opts = {
    width = 30,
    height = 10,
    digits = rows.gutter_digits(parse),
    wrap = false,
    hscroll = 0,
    reviewed = {},
    selected = 1,
  }
  local a = rows.window(parse.rows, 1, opts)
  opts.hscroll = 8
  local b = rows.window(parse.rows, 1, opts)
  local function text_of(line)
    local out = {}
    for _, run in ipairs(line) do
      out[#out + 1] = run.text
    end
    return table.concat(out)
  end
  local gutter = rows.gutter_width(opts.digits)
  eq("gutter unchanged by scrolling", text_of(a[3]):sub(1, gutter), text_of(b[3]):sub(1, gutter))
  check("body moved", text_of(a[3]) ~= text_of(b[3]))
  eq("every line is the full width", rows.len(text_of(b[3])), opts.width)
end

print("== utf8 ==")
do
  local body = lines_of(
    "diff --git a/u.txt b/u.txt\n--- a/u.txt\n+++ b/u.txt\n@@ -1,1 +1,1 @@\n+Rosé Piné ── ╭╮ é"
      .. string.rep("é", 60)
  )
  local parse = diff.parse("u", body, 0)
  local opts = {
    width = 40,
    height = 10,
    digits = rows.gutter_digits(parse),
    wrap = true,
    hscroll = 0,
    reviewed = {},
    selected = 1,
  }
  local out = rows.window(parse.rows, 1, opts)
  for index, line in ipairs(out) do
    local total = 0
    for _, run in ipairs(line) do
      total = total + rows.len(run.text)
    end
    if total ~= opts.width then
      check("every wrapped line measures the full width", false, "line " .. index .. " = " .. total)
      break
    end
  end
  check("every wrapped line measures the full width", true)
end

print("== find ==")
do
  local parse = diff.parse("find", SAMPLE, 0)
  local hits = 0
  for at = 1, #parse.rows do
    if rows.text_of(parse.rows[at]):lower():find("also", 1, true) then
      hits = hits + 1
    end
  end
  eq("one row contains 'also'", hits, 1)
end

print("== export ==")
do
  local parse = diff.parse("x", SAMPLE, 0)
  local at
  for index, row in ipairs(parse.rows) do
    if row.kind == "line" and row.file == 1 then
      at = index
      break
    end
  end
  local session = { name = "demo", base_branch = "main" }
  local md = export.markdown(session, parse, at, { ["src/two.rs"] = true })
  check("names the range", md:find("main..HEAD", 1, true) ~= nil)
  check("lists every file", md:find("src/one.lua", 1, true) and md:find("new/name.txt", 1, true))
  check("marks the reviewed one", md:find("(reviewed)", 1, true) ~= nil)
  check("quotes the hunk it is standing in", md:find("```diff", 1, true) ~= nil)
  check("quotes from the right file", md:find("Looking at `src/one.lua`", 1, true) ~= nil)
end

print("== incremental parse converges ==")
do
  -- A body larger than one bite: it must take several frames and end identical
  -- to a single-bite parse of the same body.
  local big = {}
  big[#big + 1] = "diff --git a/big.txt b/big.txt"
  big[#big + 1] = "--- a/big.txt"
  big[#big + 1] = "+++ b/big.txt"
  big[#big + 1] = "@@ -1,20000 +1,20000 @@"
  for i = 1, 20000 do
    big[#big + 1] = "+line " .. i
  end

  local before = diff.LINES_PER_FRAME
  diff.LINES_PER_FRAME = 8000
  diff.forget("big")
  local frames = 0
  local parse
  repeat
    parse = diff.parse("big", big, 0)
    frames = frames + 1
  until parse.done or frames > 20
  check("takes more than one frame", frames > 1, "frames = " .. frames)
  check("converges", parse.done)
  eq("every line arrived", parse.files[1].added, 20000)

  diff.LINES_PER_FRAME = 1e9
  diff.forget("big")
  local whole = diff.parse("big", big, 0)
  eq("same row count as a single-bite parse", #parse.rows, #whole.rows)
  diff.LINES_PER_FRAME = before
end

print("== the epoch invalidates ==")
do
  local a = lines_of("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,1 +1,1 @@\n+one")
  local b = lines_of("diff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -1,1 +1,1 @@\n+two")
  diff.forget("e")
  local first = diff.parse("e", a, 0)
  eq("first body", first.files[1].path, "a")
  local second = diff.parse("e", b, 1)
  eq("a new epoch reparses", second.files[1].path, "b")
  -- Same length, different content, same epoch: the fingerprint is the backstop.
  local third = diff.parse("e", a, 1)
  eq("the fingerprint catches a same-length change", third.files[1].path, "a")
end

print(string.format("\n%d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
