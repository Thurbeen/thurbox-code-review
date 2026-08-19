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

print("== side by side pairs a deletion with the addition that replaced it ==")
do
  -- Three shapes in one hunk: an even swap, a change that adds more than it
  -- removes, and one that removes more than it adds. The uneven ones are where
  -- positional alignment has to leave a half blank rather than mis-pair.
  local body = lines_of([[
diff --git a/p.txt b/p.txt
--- a/p.txt
+++ b/p.txt
@@ -1,9 +1,10 @@
 context before
-one gone
-two gone
+one new
+two new
 between
-only removed
+first added
+second added
+third added
 context after
]])
  local parse = diff.parse("sbs", body, 0)
  local paired = diff.paired(parse)

  local function shape(row)
    local old = row.old and parse.rows[row.old].text or nil
    local new = row.new and parse.rows[row.new].text or nil
    return (old or "-") .. " | " .. (new or "-")
  end

  local body_rows = {}
  for _, row in ipairs(paired) do
    if row.kind == "pair" then
      body_rows[#body_rows + 1] = shape(row)
    end
  end

  eq("a context line pairs with itself", body_rows[1], "context before | context before")
  eq("an even swap aligns positionally", body_rows[2], "one gone | one new")
  eq("and so does its partner", body_rows[3], "two gone | two new")
  eq("context again", body_rows[4], "between | between")
  eq("an uneven change pairs what it can", body_rows[5], "only removed | first added")
  eq("and leaves the old side blank", body_rows[6], "- | second added")
  eq("for every extra addition", body_rows[7], "- | third added")
  eq("then context", body_rows[8], "context after | context after")
  eq("nothing else", #body_rows, 8)

  -- Every canonical body line appears exactly once, on exactly one side. This is
  -- the property that makes the paired list a VIEW and not a lossy summary.
  --- Count an appearance, written out rather than looped over
  --- `{ row.old, row.new }`: half a pair is nil, and `ipairs` STOPS at the first
  --- hole — so a pair with a blank old side recorded neither of its sides and
  --- the check reported a line as unplaced that the assertions above had just
  --- shown in place.
  local seen = {}
  local function saw(index)
    if index then
      seen[index] = (seen[index] or 0) + 1
    end
  end
  for _, row in ipairs(paired) do
    if row.kind == "pair" then
      saw(row.old)
      saw(row.new)
    end
  end
  local lines, once, why = 0, true, nil
  for at, row in ipairs(parse.rows) do
    if row.kind == "line" then
      lines = lines + 1
      -- A context line is on BOTH sides of one row, which is one appearance of
      -- one row; everything else appears once.
      local want = row.side == "ctx" and 2 or 1
      if seen[at] ~= want then
        once = false
        why = why
          or string.format(
            "%q (%s) placed %s times, want %d",
            row.text,
            row.side,
            tostring(seen[at]),
            want
          )
      end
    end
  end
  check("every body line is placed exactly once", once, why)
  eq("and none was invented", lines, 11)

  -- The rule: one logical row is one selectable unit. Pairing MERGES rows, so
  -- the paired list must be shorter than the unified one by the number of
  -- deletions that found a partner.
  check("the paired list is shorter", #paired < #parse.rows, #paired .. " vs " .. #parse.rows)
end

print("== toggling the layout keeps your place ==")
do
  local body = lines_of([[
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,4 +1,4 @@
 one
-two
+TWO
 three
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1,2 +1,2 @@
 four
-five
+FIVE
]])
  local parse = diff.parse("remap", body, 0)
  local paired = diff.paired(parse)

  -- Standing on `-five` in the unified list must land on the pair holding it,
  -- not on whatever index that number happens to be in a shorter list.
  local at
  for index, row in ipairs(parse.rows) do
    if row.kind == "line" and row.text == "five" then
      at = index
    end
  end
  local to = diff.remap(parse, parse.rows, at, paired)
  eq("the pair holds the line you were on", paired[to].old, at)
  eq("and it is a pair", paired[to].kind, "pair")

  -- And back again.
  eq("round trips", diff.remap(parse, paired, to, parse.rows), at)

  -- A file header is the same table in both lists, so it maps by identity.
  local file_at
  for index, row in ipairs(parse.rows) do
    if row.kind == "file" and row.path == "b.txt" then
      file_at = index
    end
  end
  local file_to = diff.remap(parse, parse.rows, file_at, paired)
  check("a file row maps to itself", paired[file_to] == parse.rows[file_at])
end

print("== syntax ==")
do
  local syntax = require("thurbox-code-review.lib.syntax")

  eq("lua comments are --", syntax.lang_for("a/b/c.lua").line, "--")
  eq("python comments are #", syntax.lang_for("x.py").line, "#")
  eq("rust comments are //", syntax.lang_for("x.rs").line, "//")
  eq("an extensionless name still resolves", syntax.lang_for("Dockerfile").line, "#")
  eq("and an unknown one falls back", syntax.lang_for("x.zzz").line, "//")

  -- PER LANGUAGE, which is the point of the families. One union across every
  -- language accented `end` in Rust and `fn` in Python — a word that is a
  -- keyword somewhere lighting up everywhere.
  local function is_keyword(path, word)
    return syntax.lang_for(path).keywords[word] == true
  end
  check("`end` is a keyword in lua", is_keyword("x.lua", "end"))
  check("and is NOT one in rust", not is_keyword("x.rs", "end"))
  check("`fn` is a keyword in rust", is_keyword("x.rs", "fn"))
  check("and is NOT one in python", not is_keyword("x.py", "fn"))
  check("`elif` is python's", is_keyword("x.py", "elif"))
  check("and not lua's", not is_keyword("x.lua", "elif"))
  check("an unknown extension still knows something", is_keyword("x.zzz", "return"))

  local lua = syntax.lang_for("x.lua")
  local function classify(text, lang)
    local out = {}
    for _, span in ipairs(syntax.spans(text, lang or lua)) do
      out[#out + 1] = span.class .. ":" .. text:sub(span.from, span.to)
    end
    return table.concat(out, "|")
  end

  eq("a keyword", classify("local x"), "keyword:local|plain: |plain:x")
  eq("a number", classify("42"), "number:42")
  eq("a decimal is one number", classify("3.14"), "number:3.14")
  eq("a string", classify('"hi"'), 'string:"hi"')
  eq("an escaped quote does not end it", classify('"a\\"b"'), 'string:"a\\"b"')
  eq("a capitalised word is a type", classify("Foo"), "type:Foo")
  eq("a lua comment", classify("-- note"), "comment:-- note")
  check(
    "and `--` is NOT a comment in rust",
    classify("-- note", syntax.lang_for("x.rs")):find("comment") == nil
  )

  -- Every span must cover the text exactly once, in order: a lexer that drops a
  -- character silently shortens a line, and a line that is short by one walks
  -- every column after it.
  local function covers(text, lang)
    local at = 1
    for _, span in ipairs(syntax.spans(text, lang or lua)) do
      if span.from ~= at then
        return false, ("gap or overlap at %d (span starts %d)"):format(at, span.from)
      end
      at = span.to + 1
    end
    return at == #text + 1, ("covered %d of %d bytes"):format(at - 1, #text)
  end
  for _, sample in ipairs({
    "local function greet(name) -- hi",
    'return "a" .. b .. 42',
    "  if Foo.bar ~= nil then",
    "",
    "     ",
    "Rosé Piné ── ╭╮ é",
    '"unterminated',
    "x = 'it\\'s'",
    "###",
    "a//b",
  }) do
    local ok, why = covers(sample)
    check("covers " .. string.format("%q", sample), ok, why)
  end

  -- utf8 safety: the spans are byte offsets, and slicing at one must never cut
  -- a character in half. Re-joining the slices has to give the original back.
  local text = 'local s = "Rosé ── ╭╮" -- é'
  local joined = {}
  for _, span in ipairs(syntax.spans(text, lua)) do
    joined[#joined + 1] = text:sub(span.from, span.to)
  end
  eq("re-joining the spans gives the line back", table.concat(joined), text)
  check(
    "and every slice is valid utf8",
    (function()
      for _, piece in ipairs(joined) do
        if not utf8.len(piece) then
          return false
        end
      end
      return true
    end)()
  )
end

print("== regions that outlive a line ==")
do
  local syntax = require("thurbox-code-review.lib.syntax")
  local rust = syntax.lang_for("x.rs")
  local lua_lang = syntax.lang_for("x.lua")

  -- What a line LEAVES behind.
  eq("plain code leaves code", syntax.after(syntax.CODE, "let x = 1;", rust), syntax.CODE)
  eq("an opened block leaves a comment", syntax.after(syntax.CODE, "/* open", rust), syntax.COMMENT)
  eq("opened and closed leaves code", syntax.after(syntax.CODE, "/* both */ x", rust), syntax.CODE)
  eq("a comment continues", syntax.after(syntax.COMMENT, "still inside", rust), syntax.COMMENT)
  eq("until it closes", syntax.after(syntax.COMMENT, "done */ code", rust), syntax.CODE)
  -- A `//` cannot open a block, and nothing after it counts.
  eq(
    "a line comment swallows a would-be opener",
    syntax.after(syntax.CODE, "// /*", rust),
    syntax.CODE
  )
  -- A quote inside a string cannot open a region either.
  eq("a string hides its contents", syntax.after(syntax.CODE, 'let s = "/*";', rust), syntax.CODE)
  eq("lua long strings span too", syntax.after(syntax.CODE, "local s = [[", lua_lang), syntax.RAW)

  -- A line STARTING inside a comment is a comment, whatever it looks like.
  local spans = syntax.spans("let x = 1; still comment", rust, syntax.COMMENT)
  eq("one span", #spans, 1)
  eq("all of it comment", spans[1].class, "comment")
  -- And it stops at the close.
  local mixed = syntax.spans("done */ let y = 2;", rust, syntax.COMMENT)
  eq("the comment ends", mixed[1].class, "comment")
  eq("where it closes", mixed[1].to, 7)
  local found_keyword = false
  for _, span in ipairs(mixed) do
    if span.class == "keyword" then
      found_keyword = true
    end
  end
  check("and code after it is code again", found_keyword)
end

print("== a region belongs to one SIDE of the diff ==")
do
  local syntax = require("thurbox-code-review.lib.syntax")
  -- A comment opened in a REMOVED line is not open in the ADDED one: they are
  -- two versions of the same file. Getting this wrong lights up the rest of any
  -- hunk that edits a comment.
  local body = lines_of([[
diff --git a/x.rs b/x.rs
--- a/x.rs
+++ b/x.rs
@@ -1,6 +1,6 @@
 fn main() {
-    /* old note
-       continues */
+    /* new note
+       also continues */
     let x = 1;
]])
  local parse = diff.parse("sides", body, 0)
  local lang_of = function(row)
    return syntax.lang_of(parse, row.file)
  end

  --- The region each body line starts in, asked for the way the renderer asks:
  --- per row, bounded by its hunk.
  local seen = {}
  for index, row in ipairs(parse.rows) do
    if row.kind == "line" then
      local old_state, new_state = syntax.state_at(parse.rows, index, lang_of)
      seen[#seen + 1] = row.side .. ":" .. syntax.for_side(row.side, old_state, new_state)
    end
  end
  eq("context starts in code", seen[1], "ctx:code")
  eq("the removed opener starts in code", seen[2], "del:code")
  eq("its continuation is inside a comment", seen[3], "del:comment")
  eq("the ADDED opener also starts in code", seen[4], "add:code")
  eq("its own continuation is inside its own comment", seen[5], "add:comment")
  eq("and the context after both is code again", seen[6], "ctx:code")
end

print("== a hunk starts fresh, because its context is missing ==")
do
  local syntax = require("thurbox-code-review.lib.syntax")
  local body = lines_of([[
diff --git a/x.rs b/x.rs
--- a/x.rs
+++ b/x.rs
@@ -1,2 +1,2 @@
 /* opened here
 and never closed
@@ -40,2 +40,2 @@
 let y = 2;
 fn other() {}
]])
  local parse = diff.parse("hunks", body, 0)
  local lang_of = function(row)
    return syntax.lang_of(parse, row.file)
  end
  local states = {}
  for index, row in ipairs(parse.rows) do
    if row.kind == "line" then
      local old_state, new_state = syntax.state_at(parse.rows, index, lang_of)
      states[#states + 1] = syntax.for_side(row.side, old_state, new_state)
    end
  end
  eq("the first line is code", states[1], "code")
  eq("the second is inside the comment it opened", states[2], "comment")
  -- The second hunk is elsewhere in the file, with the closing `*/` in lines git
  -- never printed. Carrying the state there would be confidently wrong.
  eq("the next HUNK starts fresh", states[3], "code")
  eq("and stays code", states[4], "code")
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

-- ── the review target ───────────────────────────────────────────────────────

local target = require("thurbox-code-review.lib.target")

print("== a target is a key, and the key is a round trip ==")
do
  local fake = {}
  eq("the kernel's own", target.key(nil), "default")
  eq("working", target.key({ kind = "working" }), "working")
  eq("a commit", target.key({ kind = "commit", sha = "a1b2c3d" }), "commit:a1b2c3d")

  target.set(fake, "s1", { kind = "commit", sha = "deadbee" })
  local back = target.of(fake, "s1")
  eq("survives the round trip", back and back.kind, "commit")
  eq("with its sha", back and back.sha, "deadbee")

  -- A key this pane did not write is not a target. `state` outlives a reload and
  -- an older version of this plugin could have left anything there.
  fake["target:s2"] = "not-a-target"
  eq("junk reads as the default", target.of(fake, "s2"), nil)
  fake["target:s3"] = "commit:zzz"
  eq("a non-hex sha is junk too", target.of(fake, "s3"), nil)

  target.set(fake, "s1", nil)
  eq("and clears", target.of(fake, "s1"), nil)
end

print("== who serves which target ==")
do
  local with = { id = "s1", base_branch = "main" }
  local without = { id = "s2" }
  check("the default is always the kernel's", target.kernel_serves(with, nil))
  check("branch, when there is a base", target.kernel_serves(with, { kind = "branch" }))
  check("working, when there is not", target.kernel_serves(without, { kind = "working" }))
  -- The two that need `run`, and they are the two v1 had that the kernel does
  -- not compute. If either of these ever reads true, the pane silently draws the
  -- wrong diff rather than failing.
  check(
    "working is NOT the kernel's when there is a base",
    not target.kernel_serves(with, { kind = "working" })
  )
  check("a commit never is", not target.kernel_serves(with, { kind = "commit", sha = "abc" }))
end

print("== what a target is called ==")
do
  local session = { id = "s1", base_branch = "main" }
  eq("the default names the range", target.label(nil, session, {}), "main..HEAD")
  eq("so does the branch", target.label({ kind = "branch" }, session, {}), "main..HEAD")
  eq("working says so", target.label({ kind = "working" }, session, {}), "uncommitted changes")
  eq(
    "a commit carries its subject",
    target.label({ kind = "commit", sha = "a1b2c3d" }, session, {
      { sha = "a1b2c3d", subject = "fix the thing" },
    }),
    "a1b2c3d fix the thing"
  )
  -- Before the log arrives there is no subject, and the sha is still the answer.
  eq(
    "and its sha alone when the list is not in yet",
    target.label({ kind = "commit", sha = "a1b2c3d" }, session, {}),
    "a1b2c3d"
  )
  eq("no base, no range", target.label(nil, { id = "s2" }, {}), "uncommitted changes")
end

print("== the changed-file list, from git's own bytes ==")
do
  -- Captured from a real `git diff --no-color --numstat --raw -M -z HEAD~1..HEAD`
  -- over a repo with one addition, one deletion and one rename-with-edit. Real
  -- bytes rather than a hand-written approximation: every parser this pane has
  -- broken was broken on a shape somebody assumed.
  local captured = table.concat({
    ":000000 100644 0000000 3e75765 A\0added.txt\0",
    ":100644 000000 587be6b 0000000 D\0gone.txt\0",
    ":100644 100644 de98044 d68dd40 R075\0old.txt\0renamed.txt\0",
    "1\t0\tadded.txt\0",
    "0\t1\tgone.txt\0",
    "1\t0\t\0old.txt\0renamed.txt\0",
  })
  local files = target.parse_files(captured)
  eq("three files", #files, 3)
  eq("the addition", files[1].path, "added.txt")
  eq("is an A", files[1].status, "A")
  eq("with its counts", files[1].added .. "/" .. files[1].removed, "1/0")
  eq("the deletion", files[2].path, "gone.txt")
  eq("is a D", files[2].status, "D")
  -- A rename is keyed on the NEW path, with the old carried beside it — the same
  -- shape `session::review::parse_changed_files` produces, because the pane's
  -- file rows and every note anchored to one are keyed on that path.
  eq("the rename lands on its new name", files[3].path, "renamed.txt")
  eq("is an R", files[3].status, "R")
  eq("and remembers the old one", files[3].old_path, "old.txt")
  eq("with the edit counted", files[3].added, 1)

  -- A binary file has no line counts, and `-` is not a number.
  local binary = ":100644 100644 aaa bbb M\0logo.png\0-\t-\tlogo.png\0"
  local one = target.parse_files(binary)
  eq("a binary file is listed", one[1] and one[1].path, "logo.png")
  eq("with no additions", one[1] and one[1].added, 0)
  eq("and no removals", one[1] and one[1].removed, 0)

  eq("nothing changed is no files", #target.parse_files(""), 0)
end

print("== a capture that was cut is cut on a LINE ==")
do
  local whole = "diff --git a/a b/a\n@@ -1 +1 @@\n+one\n"
  eq("every line, when it is whole", #target.split_lines(whole, false), 3)
  -- The kernel cuts its 4 MiB on a line boundary; a run's 256 KiB lands wherever
  -- it lands. The half line goes, because a truncated `+two` parses as a real
  -- addition of a line that does not exist.
  local cut = "diff --git a/a b/a\n@@ -1 +1 @@\n+one\n+tw"
  eq("the half line is dropped", #target.split_lines(cut, true), 3)
  eq("and the whole ones are kept", target.split_lines(cut, true)[3], "+one")
  -- Not truncated and no trailing newline: that last line is real.
  eq("an untruncated last line stays", #target.split_lines(cut, false), 4)
end

print("== the scope names the session and the target ==")
do
  eq("the default", target.scope("s1", nil), "s1\1default")
  eq("a commit", target.scope("s1", { kind = "commit", sha = "abc1234" }), "s1\1commit:abc1234")
  check(
    "two targets never share a scope",
    target.scope("s1", { kind = "working" }) ~= target.scope("s1", { kind = "branch" })
  )
end

print(string.format("\n%d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
