-- thurbox's `lib/chrome`, and the focus language this pane speaks through it.
--
-- thurbox v2.35 made the focused pane unmistakable: thick `┏━┓┃` borders against
-- thin rounded ones, a ` ▸ ` mark on a bold title badge, and the theme's
-- `border_focused` / `border_unfocused` roles. `lib/chrome` gained the names that
-- say so — `level`, `border_type`, `rule`, `label`, `frame`, `MARK` — and the
-- kernel learned `border_type = "thick"`.
--
-- Neither exists before v2.35: the names are nil and the kernel refuses the
-- border. `plugin.toml`'s `requires_thurbox` is advisory, so the pane can still
-- be loaded there, and it must draw rather than fail. On a thurbox that has them
-- this module IS `lib/chrome`; on one that does not, it is `lib/chrome` with
-- the missing names filled in by the look that release's own panes have — the
-- rounded border, accented while unfocused, and an unmarked title. The one
-- difference: the focused empty pane is that rounded frame too, where the older
-- release drew a square, muted one whatever the focus.
--
-- The agent pane requires this in place of `lib.chrome` and is otherwise
-- upstream's line for line, so the next upstream change is still a merge.

local chrome = require("lib.chrome")

if chrome.level and chrome.border_type and chrome.rule and chrome.label and chrome.frame then
  return chrome
end

local legacy = setmetatable({ MARK = "▸" }, { __index = chrome })

--- Before v2.35 an unfocused agent pane stayed lit: `active`, not `inactive`.
function legacy.level(focused)
  return focused and "focused" or "active"
end

function legacy.border_type()
  return "rounded"
end

function legacy.rule()
  return "─"
end

function legacy.label(text)
  return " " .. text .. " "
end

function legacy.frame(title, level)
  return {
    title = { { text = legacy.label(title, level), style = chrome.title_style(level) } },
    border_type = "rounded",
    border_style = chrome.border_style(level),
  }
end

return legacy
