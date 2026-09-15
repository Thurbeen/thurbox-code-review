-- The agent pane this plugin ships: Agent / Shell / Review as three tabs of one
-- pane, against a faked snapshot.
--
-- Two questions, asked of the returned node trees and of the handlers:
--
--   * does Review behave as a tab — the same chip, keys, per-session memory and
--     click as Shell — rather than as a second occupant of the centre;
--   * do Agent and Shell still behave EXACTLY as the pane thurbox ships, which
--     is loaded from the pinned tag's `ui/` and rendered side by side with this
--     one.
--
-- Run it through `tests/run.sh --render`.

local REPO = assert(os.getenv("REPO"), "REPO=")
local UI = assert(os.getenv("UI"), "UI=")

dofile(REPO .. "/tests/text.lua")

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

--- A copy on every read and every write, as the real VM hands them out.
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

local function clear(held)
  for key in pairs(held) do
    held[key] = nil
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

-- ── the two panes ───────────────────────────────────────────────────────────

local shipped = assert(loadfile(UI .. "/plugins/20_agent.lua"))()
local fork = assert(loadfile(REPO .. "/plugins/20_agent.lua"))()

-- ── the snapshot ────────────────────────────────────────────────────────────

local S1 = {
  id = "s1",
  name = "demo",
  agent = "claude",
  status = "idle",
  branch = "demo/x",
  base_branch = "main",
}
local S2 = { id = "s2", name = "other", agent = "claude", status = "working" }

local function body_of(files, lines)
  local out = {}
  for f = 1, files do
    out[#out + 1] = "diff --git a/pkg/file" .. f .. ".txt b/pkg/file" .. f .. ".txt"
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

local function ready(files, lines)
  local list = {}
  for f = 1, files do
    list[f] = { path = "pkg/file" .. f .. ".txt", added = lines, removed = lines, status = "M" }
  end
  return { state = "ready", files = list, body = body_of(files, lines), truncated = false }
end

--- The registry the kernel publishes: every plugin's declared keys, which is
--- where the strip reads its `· F8` / `· F7` hints from.
local function registry_of(plugin)
  local keys = { { action = "sessions.toggle_panel", key = "f9", plugin = "sessions" } }
  for _, binding in ipairs(plugin.keys or {}) do
    keys[#keys + 1] = {
      action = binding.action,
      key = binding.key,
      plugin = plugin.name,
      scope = binding.scope,
    }
  end
  return { keys = keys, settings = {} }
end

local function snapshot(plugin, selected)
  _G.thurbox = {
    sessions = { S1, S2 },
    diffs = { s1 = ready(3, 6) },
    theme = { name = "test", roles = roles },
    registry = registry_of(plugin),
    settings = {},
    hover = {},
    focus = "agent",
    plugins = {
      { name = "sessions", slot = "sessions", kind = "pane", state = "visible" },
      { name = "agent", slot = "center", kind = "pane", state = "visible" },
    },
    runs = {},
  }
  store_backing.selected = selected or "s1"
end

--- A clean slate: nothing remembered, nothing commanded.
local function reset(plugin, selected)
  clear(state_backing)
  clear(commands)
  store_backing.selected = nil
  snapshot(plugin, selected)
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

local function run_text(runs)
  local parts = {}
  for _, run in ipairs(runs or {}) do
    parts[#parts + 1] = run.text or ""
  end
  return table.concat(parts)
end

--- The top border's strip, as one string.
local function strip_of(tree)
  return run_text(tree.frame and tree.frame.overlay and tree.frame.overlay.top_left)
end

--- The chips on the strip: every run carrying a `terminal.*` click verb.
local function chips_of(tree)
  local out = {}
  for _, run in ipairs((tree.frame and tree.frame.overlay and tree.frame.overlay.top_left) or {}) do
    if run.role and run.role:match("^action:terminal%.") then
      out[#out + 1] = run
    end
  end
  return out
end

local function chip(tree, name)
  for _, run in ipairs(chips_of(tree)) do
    if run.text:find(name, 1, true) then
      return run
    end
  end
  return nil
end

--- A chip's background, or nil when there is no such chip.
local function bg_of(run)
  return run and run.style and run.style.bg
end

local function title_of(tree)
  local title = tree.frame and tree.frame.title
  if type(title) == "table" then
    return run_text(title)
  end
  return tostring(title or "")
end

--- Every `surface` node naming a live terminal.
local function terminals(tree)
  local out = {}
  walk(tree, function(item)
    if item.type == "surface" and item.session then
      out[#out + 1] = item.session
    end
  end)
  return out
end

local function has_body(tree)
  local found = false
  walk(tree, function(item)
    if item.type == "surface" and item.id == "body" then
      found = true
    end
  end)
  return found
end

--- Deep equality, reporting the first path that differs.
local function same(a, b, path)
  path = path or ""
  if type(a) ~= type(b) then
    return false, path .. " (" .. type(a) .. " vs " .. type(b) .. ")"
  end
  if type(a) ~= "table" then
    return a == b, path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")"
  end
  for key, value in pairs(a) do
    local ok, where = same(value, b[key], path .. "." .. tostring(key))
    if not ok then
      return false, where
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false, path .. "." .. tostring(key) .. " (absent vs present)"
    end
  end
  return true
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

local WIDE = { width = 120, height = 30, focused = true, elapsed = 0 }
local function at(width, focused)
  return { width = width, height = 30, focused = focused ~= false, elapsed = 0 }
end

-- ── three tabs ──────────────────────────────────────────────────────────────

print("== three tabs render on the border ==")
do
  reset(fork)
  local tree = fork.render(WIDE)
  local strip = strip_of(tree)
  local agent_at = strip:find(" Agent ", 1, true)
  local shell_at = strip:find(" Shell · F8 ", 1, true)
  local review_at = strip:find(" Review · F7 ", 1, true)
  check("Agent is on the strip", agent_at ~= nil, strip)
  check("Shell is on the strip, with its chord", shell_at ~= nil, strip)
  check("Review is on the strip, with its chord", review_at ~= nil, strip)
  check(
    "in that order",
    agent_at and shell_at and review_at and agent_at < shell_at and shell_at < review_at,
    strip
  )
  eq("three chips", #chips_of(tree), 3)

  local review = chip(tree, "Review") or {}
  eq("the Review chip clicks through its own select action", review.role, "action:terminal.review")
  eq("styled as an inactive chip, as Shell is", bg_of(chip(tree, "Review")), roles.selection_bg)
  eq("while Agent is the active one", bg_of(chip(tree, "Agent")), roles.accent)

  local palette = {}
  for _, entry in ipairs(fork.commands or {}) do
    palette[entry.action] = true
  end
  check("the select action is in the palette, as Shell's is", palette["terminal.review"] == true)
end

print("== the strip trims Review as it trims Shell ==")
do
  reset(fork)
  local narrow = fork.render(at(40))
  check(
    "a narrower pane drops the chords first",
    strip_of(narrow):find(" Review ", 1, true) and not strip_of(narrow):find("F7", 1, true),
    strip_of(narrow)
  )
  local tight = fork.render(at(25))
  check("tighter, the inactive Review goes", chip(tight, "Review") == nil, strip_of(tight))
  check("and Agent stays", chip(tight, "Agent") ~= nil, strip_of(tight))

  fork.on_action("terminal.review")
  local on_review = fork.render(at(25))
  check("the active Review chip is never the one dropped", chip(on_review, "Review") ~= nil)
  check("Shell goes instead", chip(on_review, "Shell") == nil, strip_of(on_review))
end

-- ── switching ───────────────────────────────────────────────────────────────

print("== the tab keys switch tabs ==")
do
  local declared = {}
  for _, binding in ipairs(fork.keys) do
    declared[binding.key] = binding
  end
  eq("F7 is the review chord", (declared.f7 or {}).action, "review.open")
  eq("global, as F8 is", (declared.f7 or {}).scope, "global")
  eq("Ctrl+X is its v1 alternate", (declared["ctrl+x"] or {}).action, "review.open")
  eq("F8 still opens the shell", (declared.f8 or {}).action, "shell.open")

  reset(fork)
  check("F7 is handled", fork.on_action("review.open"))
  eq("and shows the review", state_backing["tab:s1"], "review")
  local last = commands[#commands] or {}
  eq("bringing the pane forward, as show_tab does", last.args and last.args.text, "agent")
  check("which is not another pane: nothing else is focused", last.kind == "focus")

  local tree = fork.render(WIDE)
  eq("the Review chip is lit", bg_of(chip(tree, "Review")), roles.accent)
  check("the body is the diff", has_body(tree))
  eq("and no terminal is painted, so no key can reach one", #terminals(tree), 0)
  check("the title names what is reviewed", title_of(tree):find("main..HEAD", 1, true) ~= nil)

  check("F7 again is handled", fork.on_action("review.open"))
  eq("and toggles back to the agent", state_backing["tab:s1"], nil)
  eq("whose terminal is back", terminals(fork.render(WIDE))[1], "s1")

  fork.on_action("shell.open")
  eq("F8 shows the shell", state_backing["tab:s1"], "shell")
  fork.on_action("review.open")
  eq("F7 from the shell shows the review", state_backing["tab:s1"], "review")
  fork.on_action("shell.open")
  eq("F8 from the review shows the shell", state_backing["tab:s1"], "shell")
  fork.on_action("review.open")
  fork.on_action("review.open")
  eq("F7 twice from the shell lands on the agent, as F8 twice does", state_backing["tab:s1"], nil)
end

print("== a click on a chip selects its tab ==")
do
  -- A chip's `role` is the kernel's click verb: the kernel runs the action it
  -- names and focuses the pane. So a click IS `on_action(<that action>)`.
  reset(fork)
  local tree = fork.render(WIDE)
  local function click(name)
    local role = (chip(tree, name) or {}).role or ""
    local action = role:match("^action:(.+)$")
    return action and fork.on_action(action)
  end
  check("clicking Review is handled", click("Review"))
  eq("and shows the review", state_backing["tab:s1"], "review")
  check("clicking it again keeps it, as the Shell chip does", click("Review"))
  eq("still the review", state_backing["tab:s1"], "review")
  check("clicking Agent", click("Agent"))
  eq("shows the agent", state_backing["tab:s1"], nil)
  check("clicking Shell", click("Shell"))
  eq("shows the shell", state_backing["tab:s1"], "shell")
end

-- ── per-session memory ──────────────────────────────────────────────────────

print("== each session remembers its tab, and Review its place ==")
do
  reset(fork)
  fork.on_action("review.open")
  fork.render(WIDE)
  fork.on_action("review.top")
  for _ = 1, 4 do
    fork.on_action("review.next")
  end
  local cursor = state_backing["sel:s1"]
  local scoped = nil
  for key, value in pairs(state_backing) do
    if key:match("^sel:s1") then
      scoped = { key = key, value = value }
    end
  end
  check("the review cursor moved on s1", scoped ~= nil and scoped.value > 1)

  -- Select another session: it has its own tab, and it was never switched.
  store_backing.selected = "s2"
  eq("s2 opens on the agent", terminals(fork.render(WIDE))[1], "s2")
  fork.on_action("shell.open")
  eq("s2 can be on the shell", terminals(fork.render(WIDE))[1], "s2#shell")

  store_backing.selected = "s1"
  local back = fork.render(WIDE)
  check("s1 is still on the review", has_body(back))
  eq("with no terminal painted", #terminals(back), 0)
  eq(
    "and its cursor where it was left",
    state_backing[scoped and scoped.key or ""],
    scoped and scoped.value
  )
  check("the cursor key was per session", cursor == nil or cursor == scoped.value)

  store_backing.selected = "s2"
  eq("and s2 is still on its shell", terminals(fork.render(WIDE))[1], "s2#shell")
end

-- ── one occupant of the centre ──────────────────────────────────────────────

print("== the centre has one occupant, so the focus ring cannot stop on a review ==")
do
  local manifest = assert(io.open(REPO .. "/plugin.toml")):read("a")
  eq(
    "the manifest's pane is this agent pane",
    manifest:match('pane%s*=%s*{%s*source%s*=%s*"([^"]+)"'),
    "plugins/20_agent.lua"
  )

  local panes = {}
  local listing = assert(io.popen("ls '" .. REPO .. "/plugins'"))
  for file in listing:lines() do
    if file:match("%.lua$") then
      panes[#panes + 1] = file
    end
  end
  listing:close()
  eq("plugins/ holds one pane", #panes, 1)
  eq("and it is the agent pane", panes[1], "20_agent.lua")

  local centre = 0
  for _, file in ipairs(panes) do
    local plugin = assert(loadfile(REPO .. "/plugins/" .. file))()
    if plugin.slot == "center" then
      centre = centre + 1
    end
  end
  eq("one plugin names the centre slot", centre, 1)
  eq("it is named agent, which `session focus` addresses", fork.name, "agent")
  eq("it offers no pill: the strip is the way in", fork.pills, nil)
  check(
    "and no review module declares a slot of its own",
    not io.open(REPO .. "/plugins/40_review.lua")
  )
end

-- ── Agent and Shell, exactly as shipped ─────────────────────────────────────

print("== Agent and Shell draw what the shipped pane draws ==")
do
  local function both(tab, ctx, prepare)
    reset(shipped)
    if tab ~= "agent" then
      state_backing["tab:s1"] = tab
    end
    if prepare then
      prepare()
    end
    local held = deep_copy(state_backing)
    local want = shipped.render(ctx)
    clear(state_backing)
    for key, value in pairs(held) do
      state_backing[key] = value
    end
    snapshot(fork)
    local got = fork.render(ctx)
    return got, want
  end

  local function scrolled()
    state_backing["scroll:s1"] = 5
    state_backing["scrollmax:s1"] = 40
    state_backing["scroll:s1#shell"] = 3
    state_backing["scrollmax:s1#shell"] = 9
  end

  for _, tab in ipairs({ "agent", "shell" }) do
    for _, prepare in ipairs({ false, scrolled }) do
      for _, focused in ipairs({ true, false }) do
        local label = tab .. (prepare and ", scrolled" or "") .. (focused and "" or ", unfocused")
        local got, want = both(tab, at(120, focused), prepare or nil)

        -- The strip is the shipped strip with one chip appended: a border cell
        -- and ` Review · F7 `. Nothing before it moves.
        local got_strip = got.frame.overlay.top_left
        local want_strip = want.frame.overlay.top_left
        eq(label .. ": two more strip runs", #got_strip, #want_strip + 2)
        local prefix = {}
        for index = 1, #want_strip do
          prefix[index] = got_strip[index]
        end
        local ok, where = same(prefix, want_strip)
        check(label .. ": the shipped strip is untouched", ok, where)

        -- Everything else — the surface, its scroll, the title, the scrollbar,
        -- the border — is identical.
        got.frame.overlay.top_left, want.frame.overlay.top_left = nil, nil
        ok, where = same(got, want)
        check(label .. ": the rest of the tree is identical", ok, where)
      end
    end
  end

  -- Narrow, the strip trims differently (three chips, not two), and the title is
  -- fitted against where the strip ends. The pane underneath does not change.
  for _, tab in ipairs({ "agent", "shell" }) do
    local got, want = both(tab, at(50))
    got.frame.overlay.top_left, want.frame.overlay.top_left = nil, nil
    got.frame.title, want.frame.title = nil, nil
    local ok, where = same(got, want)
    check(tab .. " at 50 columns: identical below the strip and title", ok, where)
  end

  -- No session: the welcome frame, with no strip at all.
  reset(shipped, "nope")
  local want = shipped.render(WIDE)
  reset(fork, "nope")
  local ok, where = same(fork.render(WIDE), want)
  check("with no session, the empty frame is the shipped one", ok, where)
end

print("== Agent and Shell take keys as the shipped pane does ==")
do
  -- Every key the shipped pane declares is declared here, unchanged.
  local mine = {}
  for _, binding in ipairs(fork.keys) do
    mine[binding.key .. "=" .. binding.action] = binding
  end
  for _, binding in ipairs(shipped.keys) do
    local found = mine[binding.key .. "=" .. binding.action]
    check("declares " .. binding.key .. " → " .. binding.action, found ~= nil)
    if found then
      eq(binding.key .. " keeps its scope", found.scope, binding.scope)
    end
  end
  check("declares the same pure-ness question honestly", fork.input == shipped.input)
  eq("the same input routing", fork.input, "session")
  eq("the same slot", fork.slot, shipped.slot)
  eq("the same order", fork.order, shipped.order)

  --- Run one handler call on a pane from a given starting state, and return
  --- what it answered, the state it left and the commands it issued.
  local function outcome(plugin, tab, call)
    reset(plugin)
    if tab ~= "agent" then
      state_backing["tab:s1"] = tab
    end
    state_backing["scroll:s1"] = 5
    state_backing["scrollmax:s1"] = 5
    state_backing["scroll:s1#shell"] = 2
    state_backing["scrollmax:s1#shell"] = 2
    local answer = call(plugin)
    return { answer = answer, state = deep_copy(state_backing), commands = deep_copy(commands) }
  end

  local calls = {
    ["page up"] = function(p)
      return p.on_action("terminal.scroll_up")
    end,
    ["page down"] = function(p)
      return p.on_action("terminal.scroll_down")
    end,
    ["a typed key"] = function(p)
      return p.on_key({ char = "j", key = "j" })
    end,
    ["the wheel up"] = function(p)
      return p.on_scroll({ up = true })
    end,
    ["the wheel down"] = function(p)
      return p.on_scroll({ up = false })
    end,
    ["a scrollbar press"] = function(p)
      return p.on_click({ role = "drag", y = 3, h = 20 })
    end,
    ["an unknown click"] = function(p)
      return p.on_click({ id = "elsewhere" })
    end,
    ["the focus action"] = function(p)
      return p.on_action("terminal.focus")
    end,
    ["select agent"] = function(p)
      return p.on_action("terminal.agent")
    end,
    ["select shell"] = function(p)
      return p.on_action("terminal.shell")
    end,
    ["the shell chord"] = function(p)
      return p.on_action("shell.open")
    end,
  }
  for _, tab in ipairs({ "agent", "shell" }) do
    for name, call in pairs(calls) do
      local got, want = outcome(fork, tab, call), outcome(shipped, tab, call)
      local ok, where = same(got, want)
      check("on the " .. tab .. " tab, " .. name .. " does what it does upstream", ok, where)
    end
  end
end

print("== Review's keys are the terminal's on the other two tabs ==")
do
  -- The review declares `j`, `k`, `enter`, `esc`, `tab`… on the agent pane, and a
  -- plugin-scoped key resolves for the focused plugin whichever tab is showing.
  -- Declining is what lets the kernel carry the key on to the pty — so every one
  -- of them must decline, change nothing and issue nothing, off the Review tab.
  for _, tab in ipairs({ "agent", "shell" }) do
    for _, binding in ipairs(fork.keys) do
      local action = binding.action
      if action:match("^review%.") and action ~= "review.open" then
        reset(fork)
        if tab ~= "agent" then
          state_backing["tab:s1"] = tab
        end
        local before = deep_copy(state_backing)
        local answer = fork.on_action(action)
        local ok = answer == false and same(state_backing, before) and #commands == 0
        check(
          "on the " .. tab .. " tab, " .. binding.key .. " (" .. action .. ") falls through",
          ok
        )
      end
    end
  end

  -- A search left open on the review does not eat what you type into the agent.
  reset(fork)
  fork.on_action("review.open")
  fork.render(WIDE)
  fork.on_action("review.find")
  fork.on_action("terminal.agent")
  local query_before = deep_copy(state_backing)
  eq("a character on the agent tab is declined", fork.on_key({ char = "x", key = "x" }), false)
  local ok = same(state_backing, query_before)
  check("and the open search did not take it", ok)
end

print("== a failing review body keeps the way back ==")
do
  -- One plugin is one error panel: a throw in the diff code would blank the
  -- terminal tabs with it. The review is drawn under a guard, inside the frame,
  -- so the strip — the way back to Agent — survives.
  reset(fork)
  fork.on_action("review.open")
  local review = require("thurbox-code-review.lib.review")
  local real = review.render
  review.render = function()
    error("boom")
  end
  local ok, tree = pcall(fork.render, WIDE)
  review.render = real
  check("the pane still renders", ok, tostring(tree))
  if ok then
    check("with its strip", chip(tree, "Agent") ~= nil and chip(tree, "Review") ~= nil)
    local said = false
    walk(tree, function(item)
      if item.type == "text" and type(item.text) == "table" then
        for _, line in ipairs(item.text) do
          if run_text(line):find("boom", 1, true) then
            said = true
          end
        end
      end
    end)
    check("and the error said inside it", said)
  end
end

print(string.format("\n%d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
