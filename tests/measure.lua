-- Measures the plugin's per-frame cost in the same unit the kernel budgets in.
--
-- `kernel::host::Budget::arm` installs a count hook every 100_000 instructions
-- and allows `INSTRUCTION_BUDGET / 100_000` = 200 batches per call. This counts
-- batches the same way, so the numbers below are directly comparable to 200.

local REPO = assert(os.getenv("REPO"), "REPO=")
local UI = assert(os.getenv("UI"), "UI=")
local DIFF = os.getenv("DIFF")

local roles = setmetatable({}, {
  __index = function()
    return "#808080"
  end,
})
_G.thurbox = { theme = { name = "test", roles = roles }, registry = { settings = {} } }

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

local diff = require("thurbox-code-review.lib.diff")
local rows = require("thurbox-code-review.lib.rows")

local HOOK_INTERVAL = 100000

--- Run `fn`, returning the batches of `HOOK_INTERVAL` instructions it spent.
local function cost(fn)
  local batches = 0
  debug.sethook(function()
    batches = batches + 1
  end, "", HOOK_INTERVAL)
  fn()
  debug.sethook()
  return batches
end

-- ── the body under test ─────────────────────────────────────────────────────

local body = {}
if DIFF then
  for line in io.lines(DIFF) do
    body[#body + 1] = line
  end
else
  body[#body + 1] = "diff --git a/x b/x"
  body[#body + 1] = "--- a/x"
  body[#body + 1] = "+++ b/x"
  body[#body + 1] = "@@ -1,50000 +1,50000 @@"
  for i = 1, 50000 do
    body[#body + 1] = (i % 3 == 0 and "+" or (i % 3 == 1 and "-" or " "))
      .. "some plausible line of source "
      .. i
      .. " with a tail on it"
  end
end
print(string.format("body: %d lines", #body))

-- ── parse cost ──────────────────────────────────────────────────────────────

for _, bite in ipairs({ 2000, 4000, 8000, 16000, 32000 }) do
  diff.LINES_PER_FRAME = bite
  diff.forget("m")
  local first = cost(function()
    diff.parse("m", body, 0)
  end)
  print(
    string.format(
      "  parse %6d lines/frame -> %3d batches (%.0f instructions/line)",
      bite,
      first,
      first * HOOK_INTERVAL / math.min(bite, #body)
    )
  )
end

-- ── render cost, on a finished parse ────────────────────────────────────────

diff.LINES_PER_FRAME = 1e9
diff.forget("m")
local parse = diff.parse("m", body, 0)
print(string.format("  rows: %d logical", #parse.rows))

local digits = rows.gutter_digits(parse)
for _, shape in ipairs({
  { width = 120, height = 40, wrap = false },
  { width = 120, height = 40, wrap = true },
  { width = 40, height = 40, wrap = true },
  { width = 120, height = 200, wrap = true },
}) do
  local opts = {
    width = shape.width,
    height = shape.height,
    digits = digits,
    wrap = shape.wrap,
    hscroll = 0,
    query = "line",
    reviewed = {},
    selected = math.floor(#parse.rows / 2),
  }
  local batches = cost(function()
    -- One frame: the window, drawn from a scroll anchor near the cursor.
    rows.window(parse.rows, math.max(1, opts.selected - 5), opts)
  end)
  print(
    string.format(
      "  render %3dx%-3d wrap=%-5s -> %d batches",
      shape.width,
      shape.height,
      tostring(shape.wrap),
      batches
    )
  )
end

-- ── what syntax highlighting costs a frame ──────────────────────────────────
--
-- Per VISIBLE line, so bounded by the pane's height rather than by the diff.
-- The interesting number is the difference, not the total.

local syntax = require("thurbox-code-review.lib.syntax")
for _, shape in ipairs({ { 120, 40 }, { 200, 60 } }) do
  local opts_off = {
    width = shape[1],
    height = shape[2],
    digits = digits,
    wrap = false,
    hscroll = 0,
    reviewed = {},
    canonical = parse.rows,
    selected = math.floor(#parse.rows / 2),
  }
  local opts_on = {}
  for k, v in pairs(opts_off) do
    opts_on[k] = v
  end
  opts_on.lang_of = function(row)
    return syntax.lang_of(parse, row.file)
  end
  local from = math.max(1, opts_off.selected - 5)
  local off = cost(function()
    for _ = 1, 20 do
      rows.window(parse.rows, from, opts_off)
    end
  end)
  local on = cost(function()
    for _ = 1, 20 do
      rows.window(parse.rows, from, opts_on)
    end
  end)
  print(
    string.format(
      "  syntax %3dx%-3d -> %2d batches off, %2d on, over 20 frames (%.2f batches/frame added)",
      shape[1],
      shape[2],
      off,
      on,
      (on - off) / 20
    )
  )
end

-- ── the steady-state frame: cache hit + window ──────────────────────────────

local steady = cost(function()
  for _ = 1, 1 do
    local p = diff.parse("m", body, 0)
    rows.window(p.rows, 1, {
      width = 120,
      height = 40,
      digits = digits,
      wrap = false,
      hscroll = 0,
      reviewed = {},
      selected = 1,
    })
  end
end)
print(string.format("  steady frame (cache hit + window) -> %d batches", steady))
print("  (the kernel allows 200 batches per call)")
