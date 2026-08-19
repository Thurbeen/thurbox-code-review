-- Syntax colouring for the diff body.
--
-- This file is the design's own claim being tested: *"syntax highlighting is a
-- property of the cells the plugin produces, so it can arrive without any kernel
-- change — which is the point of the surface."* Nothing here asks the kernel for
-- anything. It is a lexer and a colour table, and the cells come out different.
--
-- ── Why not tree-sitter, which is what neovim uses ──────────────────────────
--
-- It is not reachable, and not for want of trying: tree-sitter is a C library
-- loaded through FFI, and the plugin VM has `string`, `table`, `math`,
-- `coroutine` and `utf8` — no `package`, no loaders, no processes. A grammar
-- cannot be compiled, fetched or linked from here. That is the sandbox working
-- as designed rather than a gap to file.
--
-- Neovim's OTHER highlighter is reachable in spirit, and is what this now is:
-- `syntax/*.vim` is regions and keyword lists (`syn region`, `syn keyword`), and
-- the two things that make those files good are the two things this file gained —
-- **per-language keywords** rather than one union, and **regions that survive a
-- line ending** so a block comment is a block comment.
--
-- ── The limit a diff imposes, which no engine escapes ───────────────────────
--
-- A diff is fragments with their context missing. A hunk starting inside a block
-- comment cannot be known to be inside one, because the `/*` is in a line git
-- did not print. So state resets at every hunk header: guessing would be
-- confidently wrong, and wrong is worse here than plain.
--
-- Within a hunk the state is tracked exactly, and **per side**: a `-` line and a
-- `+` line are two different versions of the file, so a comment opened in a
-- removed line does not continue into an added one. Getting that wrong is what
-- makes a diff of a comment edit light up like a Christmas tree.

local theme = require("lib.theme")

local M = {}

-- ── languages ───────────────────────────────────────────────────────────────
--
-- One entry per family, and the families are chosen by what actually turns up in
-- a diff rather than by completeness. `keywords` is a set; `line` is the
-- line-comment marker; `block` is a comment region; `raw` is a string region
-- that may span lines.

local function set(words)
  local out = {}
  for word in string.gmatch(words, "%S+") do
    out[word] = true
  end
  return out
end

local FAMILIES = {
  rust = {
    line = "//",
    block = { "/*", "*/" },
    keywords = set([[
      fn let mut pub use mod impl struct enum trait match if else for while loop
      return const static async await move ref where as in dyn crate self Self
      super unsafe type break continue if_let while_let macro_rules extern box
      true false None Some Ok Err
    ]]),
  },
  lua = {
    line = "--",
    block = { "--[[", "]]" },
    raw = { "[[", "]]" },
    keywords = set([[
      local function end then do if else elseif for while repeat until return nil
      true false and or not in break goto self
    ]]),
  },
  python = {
    line = "#",
    raw = { '"""', '"""' },
    keywords = set([[
      def class if elif else for while return import from as with try except
      finally raise lambda None True False and or not in is pass yield global
      nonlocal assert del async await break continue self match case
    ]]),
  },
  js = {
    line = "//",
    block = { "/*", "*/" },
    keywords = set([[
      function const let var if else for while return class extends new this
      super import from export default async await try catch finally throw
      typeof instanceof in of null undefined true false interface type enum
      implements break continue switch case do yield static get set readonly
      public private protected namespace declare as satisfies
    ]]),
  },
  go = {
    line = "//",
    block = { "/*", "*/" },
    keywords = set([[
      func var const type struct interface map chan go defer if else for range
      return switch case default package import nil true false break continue
      fallthrough select goto
    ]]),
  },
  shell = {
    line = "#",
    keywords = set([[
      if then else elif fi for while until do done case esac function return
      local export readonly declare source exit shift trap set unset in select
      time coproc true false
    ]]),
  },
  c = {
    line = "//",
    block = { "/*", "*/" },
    keywords = set([[
      if else for while do return struct enum union typedef const static void int
      char float double long short unsigned signed class public private protected
      new delete this null nullptr true false template typename namespace using
      virtual override final try catch throw switch case default break continue
      sizeof inline extern volatile auto
    ]]),
  },
  ruby = {
    line = "#",
    block = { "=begin", "=end" },
    keywords = set([[
      def end class module if elsif else unless while until for do then return
      yield begin rescue ensure raise nil true false and or not self require
      require_relative attr_accessor attr_reader attr_writer case when next break
      lambda proc
    ]]),
  },
  sql = {
    line = "--",
    block = { "/*", "*/" },
    keywords = set([[
      select from where insert into values update set delete create table alter
      drop add column index view join left right inner outer full on group by
      order having limit offset as and or not null is distinct union all case
      when then else end primary key foreign references default constraint
    ]]),
  },
  toml = { line = "#", keywords = set("true false") },
  yaml = { line = "#", keywords = set("true false null yes no on off") },
  markup = { block = { "<!--", "-->" }, keywords = {} },
}

--- Every keyword in every family, for a file whose language is not one of them.
---
--- The old behaviour, kept only as the fallback it should always have been: a
--- word that is a keyword *somewhere* lights up, which is better than nothing
--- and worse than knowing. It is why `end` used to be accented in Rust.
local FALLBACK = (function()
  local out = { line = "//", block = { "/*", "*/" }, keywords = {} }
  for _, family in pairs(FAMILIES) do
    for word in pairs(family.keywords) do
      out.keywords[word] = true
    end
  end
  return out
end)()

local BY_EXTENSION = {}
local function extensions(family, list)
  for ext in string.gmatch(list, "%S+") do
    BY_EXTENSION[ext] = FAMILIES[family]
  end
end
extensions("rust", "rs")
extensions("lua", "lua")
extensions("python", "py pyi pyw")
extensions("js", "js jsx mjs cjs ts tsx")
extensions("go", "go")
extensions("shell", "sh bash zsh fish ksh")
extensions("c", "c h cc cpp cxx hpp hh java cs swift kt kts scala php m mm")
extensions("ruby", "rb rake gemspec ru")
extensions("sql", "sql")
extensions("toml", "toml ini cfg conf")
extensions("yaml", "yaml yml")
extensions("markup", "html htm xml svg md markdown")

--- Names with no extension that still say what they are.
local BY_NAME = {
  makefile = FAMILIES.shell,
  dockerfile = FAMILIES.shell,
  justfile = FAMILIES.shell,
  rakefile = FAMILIES.ruby,
  gemfile = FAMILIES.ruby,
  ["justfile.local"] = FAMILIES.shell,
}

--- The lexing rules for a path.
function M.lang_for(path)
  path = path or ""
  local ext = string.match(path, "%.([%w_]+)$")
  if ext then
    return BY_EXTENSION[string.lower(ext)] or FALLBACK
  end
  local name = string.match(path, "([^/]+)$") or ""
  return BY_NAME[string.lower(name)] or FALLBACK
end

--- The rules for a file index, cached on the parse.
function M.lang_of(parse, index)
  if not index then
    return nil
  end
  parse.langs = parse.langs or {}
  local held = parse.langs[index]
  if held then
    return held
  end
  local file = parse.files[index]
  if not file then
    return nil
  end
  held = M.lang_for(file.path)
  parse.langs[index] = held
  return held
end

-- ── the classes, and the roles they borrow ──────────────────────────────────
--
-- The palette has no syntax roles, and adding five would be a kernel change plus
-- 36 themes to fill in for one pane. These five already mean what the classes
-- mean, and are v1's own mapping (`ui::syntax`), so a v1 user sees the colours
-- they had.

local function class_colour(class)
  if class == "comment" then
    return theme.role("text_muted")
  elseif class == "string" then
    return theme.role("branch_name")
  elseif class == "number" then
    return theme.role("status_working")
  elseif class == "keyword" then
    return theme.role("accent")
  elseif class == "type" then
    return theme.role("accent_bright")
  end
  return theme.role("text_primary")
end

local function is_word_byte(byte)
  return byte
    and (
      (byte >= 48 and byte <= 57)
      or (byte >= 65 and byte <= 90)
      or (byte >= 97 and byte <= 122)
      or byte == 95
    )
end

local function starts_with(text, at, needle)
  return needle ~= nil and string.sub(text, at, at + #needle - 1) == needle
end

-- ── regions that outlive a line ─────────────────────────────────────────────

M.CODE, M.COMMENT, M.RAW = "code", "comment", "raw"

--- The state a line leaves behind.
---
--- Jumps with `string.find` rather than walking bytes. The first version tested
--- every position against every marker with `string.sub`, which is four
--- allocations per character — and measured **1444 instruction batches over a
--- capped diff against a budget of 200**. A lexer that kills the pane is not a
--- lexer. This does a handful of `find`s per line instead.
function M.after(state, text, lang)
  lang = lang or FALLBACK
  local block_open = lang.block and lang.block[1]
  local block_close = lang.block and lang.block[2]
  local raw_open = lang.raw and lang.raw[1]
  local raw_close = lang.raw and lang.raw[2]
  local at, len = 1, #text

  --- The next quote of `quote` at or after `from` that is not escaped.
  local function closing_quote(quote, from)
    local seek = from
    while seek <= len do
      local found = string.find(text, quote, seek, true)
      if not found then
        return nil
      end
      -- An odd run of backslashes escapes it; an even run escapes itself.
      local slashes = 0
      local back = found - 1
      while back >= 1 and string.byte(text, back) == 92 do
        slashes = slashes + 1
        back = back - 1
      end
      if slashes % 2 == 0 then
        return found
      end
      seek = found + 1
    end
    return nil
  end

  while at <= len do
    if state == M.COMMENT then
      local found = block_close and string.find(text, block_close, at, true)
      if not found then
        return M.COMMENT
      end
      state, at = M.CODE, found + #block_close
    elseif state == M.RAW then
      local found = raw_close and string.find(text, raw_close, at, true)
      if not found then
        return M.RAW
      end
      state, at = M.CODE, found + #raw_close
    else
      -- The earliest of: a line comment, a block opener, a raw opener, a quote.
      -- Whichever comes first decides what happens next; everything before it is
      -- ordinary code and needs no inspection at all.
      local best, kind, quote = nil, nil, nil
      local function offer(found, what)
        if found and (best == nil or found < best) then
          best, kind = found, what
        end
      end
      offer(lang.line and string.find(text, lang.line, at, true), "line")
      offer(block_open and string.find(text, block_open, at, true), "block")
      offer(raw_open and string.find(text, raw_open, at, true), "raw")
      for _, mark in ipairs({ '"', "'", "`" }) do
        local found = string.find(text, mark, at, true)
        if found and (best == nil or found < best) then
          best, kind, quote = found, "quote", mark
        end
      end

      if not best then
        return state
      elseif kind == "line" then
        -- Ends the line, so nothing after it can open anything.
        return M.CODE
      elseif kind == "block" then
        state, at = M.COMMENT, best + #block_open
      elseif kind == "raw" then
        state, at = M.RAW, best + #raw_open
      else
        local closed = closing_quote(quote, best + 1)
        if not closed then
          -- An unterminated ordinary string ends at the line, in every language
          -- here. It does not open a region.
          return state
        end
        at = closed + 1
      end
    end
  end
  return state
end

--- The regions the old and new sides are in at row `index`, exclusive.
---
--- Walks back to the enclosing hunk header and forward from there. Bounded by
--- the HUNK, not by the diff: the first version walked every row of the parse and
--- cost seven times the whole per-call budget on a capped diff. An editor gets
--- away with tokenising a whole document because it has the document and all the
--- time in the world; a pane redrawing at 60fps has neither.
---
--- Per SIDE, because a `-` line and a `+` line are two versions of the same file
--- and a comment opened in one is not open in the other. Reset at the hunk
--- header, because a hunk's first line has no predecessor in the diff — the `/*`
--- may be in a line git did not print, and guessing would be confidently wrong.
--- Lines to look back at most.
---
--- The walk is bounded by the hunk, and a hunk is normally tens of lines — but
--- nothing stops one being fifty thousand, and then every frame pays for it. Past
--- this many lines the state is taken as code: a region opened four hundred lines
--- above what you are looking at is not something a reader is tracking either,
--- and the cost of being wrong there is one stretch of plain text.
M.MAX_LOOKBACK = 400

function M.state_at(rows, index, lang_of)
  local floor = math.max(1, index - M.MAX_LOOKBACK)
  local from = floor
  for back = index - 1, floor, -1 do
    local kind = rows[back].kind
    if kind == "hunk" or kind == "file" then
      from = back + 1
      break
    end
  end

  local old_state, new_state = M.CODE, M.CODE
  for at = from, index - 1 do
    local row = rows[at]
    if row.kind == "line" then
      local lang = lang_of and lang_of(row) or nil
      local text = row.text or ""
      if row.side == "del" then
        old_state = M.after(old_state, text, lang)
      elseif row.side == "add" then
        new_state = M.after(new_state, text, lang)
      else
        local after = M.after(new_state, text, lang)
        old_state, new_state = after, after
      end
    end
  end
  return old_state, new_state
end

--- The region a single line starts in, given the running pair.
function M.for_side(side, old_state, new_state)
  if side == "del" then
    return old_state
  end
  return new_state
end

-- ── one line into spans ─────────────────────────────────────────────────────

--- Split `text` into `{ from, to, class }` spans, in order, covering all of it.
---
--- Byte offsets, not character offsets. The lexer only ever compares ASCII —
--- quotes, digits, word bytes, the markers — and every multi-byte UTF-8 sequence
--- has its high bit set, so it can never look like one of those. A span boundary
--- therefore always lands on a character boundary and the caller can slice by
--- byte safely.
---
--- `state` is the region the line starts in, from `scan`. Without it a hunk that
--- edits the middle of a block comment is highlighted as code, which is the most
--- visible thing a line-at-a-time lexer gets wrong.
function M.spans(text, lang, state)
  lang = lang or FALLBACK
  state = state or M.CODE
  local out = {}
  local at, len = 1, #text
  local plain_from = nil

  local function flush(upto)
    if plain_from and upto >= plain_from then
      out[#out + 1] = { from = plain_from, to = upto, class = "plain" }
    end
    plain_from = nil
  end

  local block_close = lang.block and lang.block[2]
  local raw_close = lang.raw and lang.raw[2]

  -- Opened before this line: the region runs until its close, or to the end.
  if state ~= M.CODE then
    local closer = state == M.COMMENT and block_close or raw_close
    local class = state == M.COMMENT and "comment" or "string"
    local to = nil
    if closer then
      local from = string.find(text, closer, 1, true)
      if from then
        to = from + #closer - 1
      end
    end
    if not to then
      if len > 0 then
        out[1] = { from = 1, to = len, class = class }
      end
      return out
    end
    out[#out + 1] = { from = 1, to = to, class = class }
    at = to + 1
  end

  while at <= len do
    if lang.line and starts_with(text, at, lang.line) then
      flush(at - 1)
      out[#out + 1] = { from = at, to = len, class = "comment" }
      return out
    end
    if lang.block and starts_with(text, at, lang.block[1]) then
      flush(at - 1)
      local from = string.find(text, lang.block[2], at + #lang.block[1], true)
      local to = from and (from + #lang.block[2] - 1) or len
      out[#out + 1] = { from = at, to = to, class = "comment" }
      at = to + 1
    elseif lang.raw and starts_with(text, at, lang.raw[1]) then
      flush(at - 1)
      local from = string.find(text, lang.raw[2], at + #lang.raw[1], true)
      local to = from and (from + #lang.raw[2] - 1) or len
      out[#out + 1] = { from = at, to = to, class = "string" }
      at = to + 1
    else
      local byte = string.byte(text, at)
      local char = string.sub(text, at, at)
      if char == '"' or char == "'" or char == "`" then
        flush(at - 1)
        local quote, to = char, at + 1
        while to <= len do
          local here = string.sub(text, to, to)
          if here == "\\" then
            to = to + 2
          elseif here == quote then
            to = to + 1
            break
          else
            to = to + 1
          end
        end
        out[#out + 1] = { from = at, to = math.min(to - 1, len), class = "string" }
        at = math.min(to, len + 1)
      elseif byte and byte >= 48 and byte <= 57 then
        flush(at - 1)
        local to = at
        while to <= len do
          local next_byte = string.byte(text, to + 1)
          local dotted = string.sub(text, to + 1, to + 1) == "."
            and string.byte(text, to + 2)
            and string.byte(text, to + 2) >= 48
            and string.byte(text, to + 2) <= 57
          if is_word_byte(next_byte) or dotted then
            to = to + 1
          else
            break
          end
        end
        out[#out + 1] = { from = at, to = to, class = "number" }
        at = to + 1
      elseif is_word_byte(byte) then
        flush(at - 1)
        local to = at
        while is_word_byte(string.byte(text, to + 1)) do
          to = to + 1
        end
        local word = string.sub(text, at, to)
        local first = string.byte(word, 1)
        local class = "plain"
        if lang.keywords[word] then
          class = "keyword"
        elseif first and first >= 65 and first <= 90 then
          class = "type"
        end
        out[#out + 1] = { from = at, to = to, class = class }
        at = to + 1
      else
        plain_from = plain_from or at
        at = at + 1
      end
    end
  end
  flush(len)
  return out
end

--- `text` as runs, coloured by class, keeping everything else in `base`.
function M.runs(text, lang, base, keep_fg, state)
  local out = {}
  for _, span in ipairs(M.spans(text, lang, state)) do
    local style = {}
    for key, value in pairs(base) do
      style[key] = value
    end
    if not keep_fg then
      style.fg = class_colour(span.class) or base.fg
    end
    out[#out + 1] = { text = string.sub(text, span.from, span.to), style = style }
  end
  if #out == 0 then
    out[1] = { text = text, style = base }
  end
  return out
end

return M
