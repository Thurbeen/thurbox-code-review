-- Doom program surface rendered inside the agent pane.
-- Settings and payload come from the separately installed thurbox-doom package.

local theme = require("lib.theme")
local widgets = require("lib.widgets")
local settings = require("lib.settings")

local NAME = "doom"

--- The program pane. Letters, digits, `-` and `_` only: the name reaches a tmux
--- window name, which tmux parses as part of a target string.
local PANE = "doom"

--- The Doom package's working copy, inside the interface directory.
---
--- `thurbox-cli plugin install git+<url>` clones a plugin that carries a payload,
--- and the clone lands at `<interface dir>/<repository name>/` — so this is the
--- REPOSITORY's name, not the plugin's. It carries the pane, engine and WAD:
---
---     <interface dir>/thurbox-doom/engine/bin/linux-x86_64/doom
---     <interface dir>/thurbox-doom/wad/doom1.wad
---
--- Other platforms can name a compatible engine with the `program` setting.
local CLONE_DIR = "thurbox-doom"

--- The WAD the Doom package ships and plays by default, as the `wad` setting's
--- DECLARED default.
---
--- Relative, and declared rather than resolved at read time, because the settings modal
--- shows a declaration: an empty default reads as "no WAD" to anyone who has not read
--- the README, which is the wrong thing to tell them about the one file this package
--- delivers. Relative to the clone, so it stays true whatever the interface directory
--- turns out to be — resolution happens below.
--- `doom1.wad` rather than `freedoom1.wad`: it is DOOM as people remember it, which is
--- the point of a DOOM pane. Both ship; `wad/NOTICE.md` says what each one is and under
--- what terms, and switching is this one setting.
local PAYLOAD_WAD = "wad/doom1.wad"

--- A path inside the Doom package's working copy, or nil when the kernel has not
--- published where the interface lives.
---
--- Absolute on purpose. A program pane has no session and therefore no repository,
--- so the kernel runs it in the interface directory — a relative path would happen
--- to work today and break the day that changes.
---
--- The join uses `/` on every platform, so on Windows the result has MIXED separators
--- (`C:\Users\me\…\ui/thurbox-doom/wad/freedoom1.wad`). That is safe for a specific
--- reason worth stating rather than assuming: Windows file APIs accept both
--- interchangeably, and this string's only destination is a program's argv — the engine
--- opens it. It would stop being safe if it were ever handed to something doing its own
--- path parsing, which is the change to notice.
---
--- Only the TRAILING separator is normalised, and both spellings are stripped there,
--- because at the end of a directory path both are unambiguously separators. Interior
--- bytes are left alone: a backslash is a legal filename character on POSIX, so
--- stripping one anywhere else would rename somebody's directory. Written down because
--- a separator assumption has twice shipped green from Linux in the kernel this runs
--- on — the second time it broke every repository install.
--- The engine builds the Doom package ships, keyed as `thurbox.platform` reports a
--- machine: `os .. "-" .. arch`.
---
--- A list rather than a stat, because a plugin cannot look at the filesystem — so the
--- pane knows what was committed and can say honestly which machine it has nothing
--- for, rather than exec'ing a path that may not exist. Building for another platform
--- is `cd engine/src && make` and dropping the result in `engine/bin/<os>-<arch>/`,
--- after which this table is the only thing in the way: add the key.
local SHIPPED_ENGINES = { ["linux-x86_64"] = true }

--- Arguments the shipped engine needs, as the `args` setting's declared default.
---
--- `-iwad` is not optional for it: without the flag it searches the working directory
--- for a handful of well-known WAD names, finds none, and exits "Game mode
--- indeterminate" — which is what a bare path bought before this default existed.
--- Clear it if you point `program` at a port that takes a positional WAD instead.
local DEFAULT_ARGS = "-iwad"

--- This platform's engine inside the clone, and the key it was looked up by — the
--- second is what the panel names when there is no first.
local function shipped_engine()
  local platform = (thurbox and thurbox.platform) or {}
  local key = tostring(platform.os or "?") .. "-" .. tostring(platform.arch or "?")
  if SHIPPED_ENGINES[key] then
    return "engine/bin/" .. key .. "/doom", key
  end
  return nil, key
end

--- Is this path already absolute? POSIX, a Windows drive letter, or a UNC share.
local function absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function payload(name)
  local dir = thurbox and thurbox.ui_dir
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return (dir:gsub("[/\\]+$", "")) .. "/" .. CLONE_DIR .. "/" .. name
end

local RESTART, RELEASE = "doom.restart", "doom.release"

local function doom_available()
  for _, entry in ipairs((thurbox and thurbox.registry and thurbox.registry.settings) or {}) do
    if entry.plugin == NAME and entry.id == "program" then
      return true
    end
  end
  return false
end

-- --- settings ---------------------------------------------------------------
--
-- Settings are declared by the Doom package and read through the shared registry.

local function setting(id, fallback)
  local value = settings.get(NAME, id, fallback)
  if value == nil then
    return fallback
  end
  return value
end

--- The program to run: what you configured, else the engine shipped for this machine,
--- else nothing.
---
--- Unset resolves to the committed build rather than to a guess — the difference being
--- that this package knows what it shipped, so either the path is there or the pane can
--- name the platform it has nothing for. Absolute is honoured as given; relative
--- resolves inside this plugin's own clone, exactly as the WAD does.
local function program()
  local named = setting("program", "")
  if type(named) == "string" and not named:match("^%s*$") then
    if absolute(named) then
      return named
    end
    return payload(named)
  end
  local engine = shipped_engine()
  if not engine then
    return nil
  end
  return payload(engine)
end

--- The argument list, as a LIST.
---
--- The multiplexer quotes each argument, so a WAD path with a space in it
--- survives being its own element and would not survive being concatenated into
--- one command line. Hence two settings rather than one: `args` is split on
--- whitespace for flags, and `wad` is appended whole.
local function args()
  local argv = {}
  local extra = setting("args", DEFAULT_ARGS)
  if type(extra) == "string" then
    for word in extra:gmatch("%S+") do
      argv[#argv + 1] = word
    end
  end
  -- An absolute WAD is used as given; anything else is resolved inside this plugin's
  -- own clone, which is what makes the declared default a path a reader can recognise
  -- rather than an empty box. With no interface directory published there is nowhere
  -- for a relative one to resolve against, so the argument is omitted rather than
  -- guessed — every port worth running looks for a WAD of its own, and a made-up path
  -- turns "no WAD" into "wrong WAD".
  local wad = setting("wad", PAYLOAD_WAD)
  if type(wad) ~= "string" or wad:match("^%s*$") then
    wad = PAYLOAD_WAD
  end
  if not absolute(wad) then
    wad = payload(wad)
  end
  if wad and wad ~= "" then
    argv[#argv + 1] = wad
  end
  return argv
end

--- The command line as a reader would type it. Shown before the grant is given,
--- so what you are about to trust is on screen rather than in a config file.
local function command_line()
  local shown = program()
  for _, argument in ipairs(args()) do
    shown = shown .. " " .. argument
  end
  return shown
end

-- --- capability -------------------------------------------------------------

--- Have we been trusted with `program`?
---
--- Asked rather than probed. A capability is normally withheld by ABSENCE — `run`
--- is not a function until you are trusted — but a program pane is asked for
--- through `command`, which every plugin has, so there is nothing to be absent.
--- `thurbox.granted` reports the decision instead, and grants nothing.
local function granted()
  local grants = (thurbox and thurbox.granted) or {}
  return grants.program == true
end

--- An error from the last `program` ask, if the kernel published one.
---
--- Worth drawing rather than swallowing: a program that is not on `PATH` fails
--- here, and this plugin cannot check `PATH` itself (no `io`, no `os`). The states
--- the kernel owns — nothing started yet, or the program has exited — it draws
--- inside the surface, which is where they belong.
local function ask_error()
  for _, item in ipairs((thurbox and thurbox.commands) or {}) do
    if item.kind == "program" and item.error and item.error ~= "" then
      return item.error
    end
  end
  return nil
end

-- --- chrome -----------------------------------------------------------------

local function line(spans)
  return { type = "text", len = 1, text = { spans } }
end

local function blank()
  return { type = "text", len = 1, text = "" }
end

--- The chord bound to an action now, so a rebind shows through rather than a
--- hardcoded hint going quietly wrong.
local function chord_for(action)
  for _, binding in ipairs((thurbox and thurbox.registry and thurbox.registry.keys) or {}) do
    if binding.action == action and binding.key then
      return binding.key
    end
  end
  return nil
end

--- A path or command line, in FULL, wrapped across as many rows as it needs.
---
--- Not `widgets.truncate`, which cuts the tail — and for a path the tail is the
--- filename, so an end-truncated path loses the half that identifies it and turns
--- the one string the reader has to retype into the one they cannot see. Reported
--- from a real install whose interface directory was long enough to cut the WAD's
--- name off.
---
--- `wrap` is a text-node field, so the kernel folds it; all this has to get right is
--- how many rows to ask for, since a box splits its height between children and a
--- one-row node would show one row of a three-row path. Past the cap it
--- middle-truncates, which keeps both ends: the directory says where, the leaf says
--- which one.
local function path_rows(text, width, cap)
  cap = cap or 3
  width = math.max(1, width)
  local rows = math.ceil(widgets.len(text) / width)
  if rows > cap then
    return widgets.middle_truncate(text, width * cap), cap
  end
  return text, math.max(1, rows)
end

--- A path node: the whole string, wrapped, in the accent colour.
local function path_line(text, width)
  local shown, rows = path_rows(text, width)
  return {
    type = "text",
    len = rows,
    wrap = true,
    text = { { { text = "  " .. shown, style = { fg = theme.accent } } } },
  }
end

--- A panel with a title, a body, and nothing clever.
local function panel(ctx, children)
  return {
    type = "box",
    axis = "vertical",
    frame = widgets.panel("DOOM", ctx.focused),
    children = children,
  }
end

--- What to draw before the capability has been granted.
---
--- The first thing every user of this plugin sees, so it says what would run, how
--- the grant is given, and why it is asked for separately. An empty pane here
--- reads as a broken plugin, and the fix is two keystrokes away in a modal the
--- reader may not know exists.
local function untrusted(ctx)
  local width = math.max(0, (ctx.width or 0) - 20)
  return panel(ctx, {
    blank(),
    line({
      { text = "  This pane wants to run a program you type at.", style = { fg = theme.text } },
    }),
    blank(),
    line({ { text = "  it would run", style = { fg = theme.muted } } }),
    path_line(command_line(), width),
    line({
      {
        text = "  configure `program` and `wad` in settings to run something else",
        style = { fg = theme.muted },
      },
    }),
    blank(),
    line({
      {
        text = "  trust it:  settings (ctrl+,) → ] → this file → ",
        style = { fg = theme.muted },
      },
      { text = "t", style = { fg = theme.hint, bold = true } },
    }),
    blank(),
    line({
      {
        text = "  Granted per file, and separately from `run`: a program that holds",
        style = { fg = theme.muted },
      },
    }),
    line({
      {
        text = "  your keystrokes is not a program you read the output of.",
        style = { fg = theme.muted },
      },
    }),
    { type = "text", fill = 1, text = "" },
  })
end

--- What to draw before a DOOM has been named.
---
--- The first thing a reader sees after installing, and the only screen that has any
--- work for them: the bundled engine only runs on linux-x86_64. It shows the WAD
--- it brought, since that is the argument the program will be handed.
local function needs_program(ctx)
  local width = math.max(0, (ctx.width or 0) - 6)
  local _, machine = shipped_engine()
  -- The resolved path, not the declaration: this line exists to be read and copied.
  local wad = nil
  local argv = args()
  if #argv > 0 then
    wad = argv[#argv]
  end
  local children = {
    blank(),
    line({
      { text = "  No engine here for ", style = { fg = theme.text } },
      { text = machine, style = { fg = theme.accent } },
      { text = ".", style = { fg = theme.text } },
    }),
    blank(),
    line({
      {
        text = "  This package ships a built DOOM for linux-x86_64 only. For yours,",
        style = { fg = theme.muted },
      },
    }),
    line({
      { text = "  build it — ", style = { fg = theme.muted } },
      { text = "cd engine/src && make", style = { fg = theme.accent } },
      { text = " — and drop the result in", style = { fg = theme.muted } },
    }),
    line({
      { text = "  engine/bin/" .. machine .. "/doom", style = { fg = theme.accent } },
      { text = ", or set ", style = { fg = theme.muted } },
      { text = "doom.program", style = { fg = theme.accent } },
      { text = " to any DOOM", style = { fg = theme.muted } },
    }),
    line({
      {
        text = "  that paints text cells and reads its keys from stdin.",
        style = { fg = theme.muted },
      },
    }),
    blank(),
  }
  if wad then
    children[#children + 1] = line({
      {
        text = "  the WAD this plugin ships, passed as the last argument:",
        style = { fg = theme.muted },
      },
    })
    children[#children + 1] = path_line(wad, width)
    children[#children + 1] = blank()
  end
  -- What is still missing, which is not the same question as what this panel is for.
  -- Naming a program and granting the capability are two prerequisites and either can
  -- be done first, so telling a reader who has already trusted this file to trust it
  -- reads as the pane not having noticed — which is exactly what it looked like to the
  -- person who reported it.
  if granted() then
    children[#children + 1] = line({
      { text = "  The ", style = { fg = theme.muted } },
      { text = "program", style = { fg = theme.accent } },
      {
        text = " capability is granted, so naming one is all that is left.",
        style = { fg = theme.muted },
      },
    })
  else
    children[#children + 1] = line({
      { text = "  Then trust it: settings → ] → this file → ", style = { fg = theme.muted } },
      { text = "t", style = { fg = theme.hint, bold = true } },
    })
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }
  return panel(ctx, children)
end

--- What to draw after the pane has been given up on purpose.
---
--- Without this there is no way back: `render` asks for the pane on every frame,
--- so a release that did not also stop the asking would be undone before the next
--- paint. The flag is the difference between "closed" and "closing".
local function released(ctx)
  local key = chord_for(RESTART) or "ctrl+alt+r"
  return panel(ctx, {
    blank(),
    line({ { text = "  DOOM released — the program was stopped.", style = { fg = theme.text } } }),
    blank(),
    widgets.hints({ { key, "start it again" } }),
    { type = "text", fill = 1, text = "" },
  })
end

--- The controls, most useful first, so trimming from the end costs least.
---
--- These are the shipped engine's, which are DOOM's own where a terminal can express
--- them and substitutes where it cannot: there is no way to see a bare `shift` or
--- `ctrl` held down, so `r` runs and `f` fires alongside whatever control byte a
--- `ctrl` chord produces. `tab` is here because the kernel does not reserve it — an
--- earlier version of this file wrongly said it did — so the automap works.
local CONTROLS = {
  { "↑↓←→/wasd", "move" },
  { "f", "fire" },
  { "space", "use" },
  { "r", "run" },
  { ", .", "strafe" },
  { "1-7", "weapon" },
  { "tab", "map" },
  { "esc", "menu" },
}

--- The widest prefix of `CONTROLS` that fits one row. `widgets.hints` packs
--- ` chord ` plus `label  `, so the cost is measurable before it is drawn.
local function controls_row(width)
  local shown, used = {}, 0
  for _, pair in ipairs(CONTROLS) do
    local cost = widgets.len(pair[1]) + widgets.len(pair[2]) + 4
    if used + cost > width then
      break
    end
    used = used + cost
    shown[#shown + 1] = pair
  end
  if #shown == 0 then
    return blank()
  end
  return widgets.hints(shown)
end

local doom = {}

doom.available = doom_available

doom.render = function(ctx)
  -- Before the grant is relevant: with no program named there is nothing to grant
  -- a capability FOR, and asking for one would be refused as a plugin error. So
  -- configuration comes first, and it is one setting.
  if not program() then
    return needs_program(ctx)
  end
  if not granted() then
    return untrusted(ctx)
  end
  if state.released then
    return released(ctx)
  end

  -- Every frame, deliberately. Asking for a pane that exists is a map lookup
  -- rather than a second copy of the program, so there is no clever place to
  -- start it once — and a pane that only asked on a keypress would come back
  -- empty after a reload.
  -- `program()` cannot be nil here: the branch above returned when it was.
  command("program", { text = PANE, repo = program(), args = args() })

  local failed = ask_error()
  local children = {
    -- The kernel fills this from the pane's own parser, and draws the states it
    -- owns: nothing behind it yet, or the program has exited. A frozen grid
    -- would look exactly like a live one, so it says which.
    { type = "surface", program = PANE, fill = 1 },
  }
  if failed then
    children[#children + 1] = line({
      {
        -- Middle-truncated, not end-truncated: a failure names a path, and the
        -- leaf is the half that says which one. One row, because it sits under
        -- the game and wrapping it would cost rows the game is using.
        text = " " .. widgets.middle_truncate(failed, math.max(0, (ctx.width or 0) - 3)),
        style = { fg = theme.bad },
      },
    })
  elseif setting("footer", true) ~= false then
    children[#children + 1] = controls_row(math.max(0, (ctx.width or 0) - 2))
  end

  return panel(ctx, children)
end

doom.on_action = function(action)
  if action == RELEASE then
    -- Stopped on purpose rather than left running unseen. The flag is what stops
    -- `render` asking for it straight back.
    command("program", { text = PANE, action = "close" })
    state.released = true
    return true
  end
  if action == RESTART then
    -- Close, then let the next frame's ask start it afresh. Also the way back
    -- from a program that exited on its own: Lua cannot see that state, so this
    -- is how you act on what the kernel drew.
    command("program", { text = PANE, action = "close" })
    state.released = nil
    return true
  end
  return false
end

return doom
