-- The `text` global the plugin VM injects: `text.width`, `text.truncate`,
-- `text.pad`.
--
-- The interface's own `lib.widgets` measures through it (thurbox #1072), so a
-- harness that loads the REAL widgets has to provide it or the first width it
-- asks for is "attempt to index a nil value". This mirrors `install_text` in
-- `src/kernel/host/api.rs` — the same cut rules, the same "never wider than
-- asked" guarantee — with a column count that knows the common double-width
-- and zero-width ranges rather than all of `unicode-width`. The tests measure
-- ASCII, box drawing and a few symbols, which this gets exactly right.

local function char_width(cp)
  if cp == 0 then
    return 0
  end
  -- Combining marks and zero-width joiners draw on the cell before them.
  if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x200B and cp <= 0x200F) or cp == 0xFE0F then
    return 0
  end
  if
    (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
  then
    return 2
  end
  return 1
end

--- Codepoints of `s` with their byte offsets, tolerating invalid UTF-8 the way
--- a lossy conversion does: one column per stray byte.
local function chars(s)
  local out = {}
  local at = 1
  while at <= #s do
    local ok, cp = pcall(utf8.codepoint, s, at)
    if ok then
      local stop = utf8.offset(s, 2, at) or (#s + 1)
      out[#out + 1] = { from = at, to = stop - 1, w = char_width(cp) }
      at = stop
    else
      out[#out + 1] = { from = at, to = at, w = 1 }
      at = at + 1
    end
  end
  return out
end

local function columns(s)
  local total = 0
  for _, ch in ipairs(chars(s)) do
    total = total + ch.w
  end
  return total
end

local function take_left(s, cols)
  local used = 0
  for _, ch in ipairs(chars(s)) do
    if used + ch.w > cols then
      return string.sub(s, 1, ch.from - 1)
    end
    used = used + ch.w
  end
  return s
end

local function take_right(s, cols)
  local list, used = chars(s), 0
  for index = #list, 1, -1 do
    local ch = list[index]
    if used + ch.w > cols then
      return string.sub(s, ch.to + 1)
    end
    used = used + ch.w
  end
  return s
end

local function cols_arg(n)
  if type(n) == "number" and n > 0 and n == n and n ~= math.huge then
    return math.floor(n)
  end
  return 0
end

local ELLIPSIS = "…"

_G.text = {
  width = columns,

  truncate = function(s, cols, opts)
    cols = cols_arg(cols)
    local ellipsis, side = ELLIPSIS, "right"
    if type(opts) == "string" then
      ellipsis = opts
    elseif type(opts) == "table" then
      ellipsis = opts.ellipsis or ELLIPSIS
      side = opts.side or "right"
      assert(side == "right" or side == "left" or side == "middle", "text.truncate: side")
    end
    if cols == 0 then
      return ""
    end
    if columns(s) <= cols then
      return s
    end
    local mark = columns(ellipsis)
    if mark >= cols then
      return take_left(ellipsis, cols)
    end
    local budget = cols - mark
    if side == "left" then
      return ellipsis .. take_right(s, budget)
    elseif side == "middle" then
      local head = math.floor(budget / 2)
      return take_left(s, head) .. ellipsis .. take_right(s, budget - head)
    end
    return take_left(s, budget) .. ellipsis
  end,

  pad = function(s, cols, align)
    local short = math.max(0, cols_arg(cols) - columns(s))
    if short == 0 then
      return s
    end
    align = align or "left"
    if align == "right" then
      return string.rep(" ", short) .. s
    elseif align == "center" or align == "centre" then
      local before = math.floor(short / 2)
      return string.rep(" ", before) .. s .. string.rep(" ", short - before)
    end
    assert(align == "left", "text.pad: align")
    return s .. string.rep(" ", short)
  end,
}
