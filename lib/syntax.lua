-- Syntax colouring for the diff body.
--
-- This file is the design's own claim being tested: *"syntax highlighting is a
-- property of the cells the plugin produces, so it can arrive without any kernel
-- change — which is the point of the surface."* Nothing below asks the kernel
-- for anything. It is a lexer and a colour table, and the cells come out
-- different.
--
-- Not a grammar engine, deliberately, and this is v1's stance rather than a
-- shortcut: a fast language-agnostic lexer that colours the things worth seeing
-- while SKIMMING a diff — comments, strings, numbers, keywords and capitalised
-- names. A real parser needs whole files, and a diff is by definition fragments
-- with their context missing; a hunk that starts mid-string or mid-block would
-- be mis-parsed with more confidence than this manages to be wrong with.
--
-- ── Colour ──────────────────────────────────────────────────────────────────
--
-- The palette has no syntax roles. There is no `syntax_keyword`, and adding one
-- would mean a kernel change and 36 themes to fill in — for a pane. So the
-- classes borrow roles that already exist, mapped exactly as v1's `ui::syntax`
-- mapped them, which means a v1 user sees the colours they had and every theme
-- covers it for free.
--
-- ── What this does NOT colour ───────────────────────────────────────────────
--
-- Add and remove. With highlighting on, the diff signal moves entirely to the
-- **sign column and the row's background tint**, and the foreground belongs to
-- the code — which is what v1 does and what every forge does, because a line
-- cannot carry two meanings in one colour. That is why `diff_added_bg` and
-- `diff_removed_bg` are worth having in the palette: without them, turning
-- highlighting on would lose the add/remove signal entirely.

local theme = require("lib.theme")

local M = {}

--- Line-comment markers by extension. v1's table.
local COMMENT = {}
local function mark(marker, extensions)
  for _, ext in ipairs(extensions) do
    COMMENT[ext] = marker
  end
end
mark("#", {
  "py",
  "rb",
  "sh",
  "bash",
  "zsh",
  "fish",
  "toml",
  "yaml",
  "yml",
  "ini",
  "cfg",
  "conf",
  "nix",
  "pl",
  "r",
  "ex",
  "exs",
  "rake",
  "gemspec",
  "just",
  "justfile",
  "dockerfile",
  "mk",
})
mark("--", { "sql", "lua", "hs", "elm", "adb", "ads" })

--- A small union of keywords across common languages.
---
--- One union rather than a table per language, for the same reason there is no
--- grammar: it makes control-flow and declaration words pop without anyone
--- maintaining a list per extension. A word that is a keyword somewhere else
--- lights up here and costs nothing — nobody misreads a diff because `match`
--- was accented in a shell script.
local KEYWORDS = {}
for _, word in ipairs({
  "fn",
  "let",
  "mut",
  "pub",
  "use",
  "mod",
  "impl",
  "struct",
  "enum",
  "trait",
  "match",
  "if",
  "else",
  "elif",
  "for",
  "while",
  "loop",
  "return",
  "const",
  "static",
  "async",
  "await",
  "move",
  "ref",
  "where",
  "as",
  "in",
  "do",
  "end",
  "then",
  "local",
  "function",
  "def",
  "class",
  "self",
  "super",
  "new",
  "delete",
  "import",
  "from",
  "export",
  "default",
  "var",
  "type",
  "interface",
  "extends",
  "implements",
  "public",
  "private",
  "protected",
  "package",
  "func",
  "go",
  "defer",
  "chan",
  "select",
  "switch",
  "case",
  "break",
  "continue",
  "try",
  "catch",
  "finally",
  "throw",
  "raise",
  "with",
  "yield",
  "lambda",
  "nil",
  "None",
  "null",
  "true",
  "false",
  "True",
  "False",
  "and",
  "or",
  "not",
  "is",
  "elseif",
  "repeat",
  "until",
  "unless",
  "begin",
  "rescue",
  "ensure",
  "module",
}) do
  KEYWORDS[word] = true
end

--- The lexing knobs for a path.
function M.lang_for(path)
  local ext = string.match(path or "", "%.([%w_]+)$")
  if not ext then
    -- A bare name with no extension: `Makefile`, `Dockerfile`, `justfile`.
    ext = string.match(path or "", "([^/]+)$") or ""
  end
  return { line_comment = COMMENT[string.lower(ext)] or "//" }
end

--- The lang for a file index, cached on the parse.
---
--- Cached because a 400-file diff would otherwise re-derive an extension for
--- every visible line of every frame — cheap each time and pointless every time.
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
      (byte >= 48 and byte <= 57) -- 0-9
      or (byte >= 65 and byte <= 90) -- A-Z
      or (byte >= 97 and byte <= 122) -- a-z
      or byte == 95 -- _
    )
end

--- Split `text` into `{ from, to, class }` spans, in order, covering all of it.
---
--- Byte offsets, not character offsets. The lexer only ever compares ASCII —
--- quotes, digits, word bytes, the comment marker — and every multi-byte UTF-8
--- sequence has its high bit set, so it can never look like one of those. A
--- run's boundaries therefore always land on a character boundary, and the
--- caller can slice by byte safely.
function M.spans(text, lang)
  local out = {}
  local marker = lang and lang.line_comment or "//"
  local at, len = 1, #text
  local plain_from = nil

  local function flush(upto)
    if plain_from and upto >= plain_from then
      out[#out + 1] = { from = plain_from, to = upto, class = "plain" }
    end
    plain_from = nil
  end

  while at <= len do
    -- A line comment swallows the rest of the line.
    if string.sub(text, at, at + #marker - 1) == marker then
      flush(at - 1)
      out[#out + 1] = { from = at, to = len, class = "comment" }
      return out
    end

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
      -- An unterminated string runs to the end of the line, which is what a
      -- diff fragment starting mid-string looks like.
      out[#out + 1] = { from = at, to = math.min(to - 1, len), class = "string" }
      at = math.min(to, len + 1)
    elseif byte and byte >= 48 and byte <= 57 then
      flush(at - 1)
      local to = at
      while to <= len do
        local next_byte = string.byte(text, to + 1)
        if
          is_word_byte(next_byte)
          or (
            string.sub(text, to + 1, to + 1) == "."
            and string.byte(text, to + 2)
            and string.byte(text, to + 2) >= 48
            and string.byte(text, to + 2) <= 57
          )
        then
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
      if KEYWORDS[word] then
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
  flush(len)
  return out
end

--- `text` as runs, coloured by class, keeping everything else in `base`.
---
--- `base.fg` is only used where a class has no opinion, so a selected row (whose
--- foreground is the selection's) can pass its own and keep it.
function M.runs(text, lang, base, keep_fg)
  local out = {}
  for _, span in ipairs(M.spans(text, lang)) do
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
