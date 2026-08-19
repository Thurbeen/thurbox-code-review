-- The review, as text, for `command("send", { session, text })`.
--
-- This is the spec's "the review can be exported to the agent" requirement, and
-- it is the one part of v1's export that v2 can express today: `command("copy",
-- …)` takes a session and copies that session's terminal, so there is no way for
-- a plugin to put arbitrary text on the clipboard. v1's `y` therefore has no
-- equivalent here, and `KERNEL-GAPS.md` records why.
--
-- What is sent is deliberately NOT the diff. The agent is standing in the
-- worktree the diff was taken from; it can read the code. What it cannot see is
-- which parts a human looked at and stopped on, so that is what goes.

local notes = require("thurbox-code-review.lib.notes")
local rows = require("thurbox-code-review.lib.rows")

local M = {}

--- Bytes of quoted context, so an export can never become a prompt nobody can
--- read. Generous for a hunk, far short of a diff.
local MAX_QUOTE = 4000

--- The `base..HEAD` the diff was taken over, in words.
function M.range(session)
  if session and session.base_branch then
    return session.base_branch .. "..HEAD"
  end
  return "uncommitted changes"
end

--- Quote the hunk the cursor is in, as a fenced diff block.
local function quote_hunk(parse, at)
  local row = parse.rows[at]
  if not row or not row.hunk then
    return nil
  end
  local file = parse.files[row.file]
  -- Walk out to the hunk's edges, then back in collecting its body lines.
  local from = at
  while from > 1 do
    local previous = parse.rows[from - 1]
    if not previous or previous.file ~= row.file or previous.hunk ~= row.hunk then
      break
    end
    from = from - 1
  end
  local out, size = {}, 0
  for index = from, #parse.rows do
    local line = parse.rows[index]
    if line.file ~= row.file or line.hunk ~= row.hunk then
      break
    end
    local text
    if line.kind == "hunk" then
      text = "@@ " .. (line.heading or "")
    else
      text = ({ add = "+", del = "-", ctx = " " })[line.side] .. (line.text or "")
    end
    size = size + #text + 1
    if size > MAX_QUOTE then
      out[#out + 1] = "… (truncated)"
      break
    end
    out[#out + 1] = text
  end
  return (file and file.path or "?"), table.concat(out, "\n")
end

--- The notes, grouped by file then the summary — v1's `review_markdown`, shape
--- for shape, so a prompt this pane sends reads like a prompt v1 sent.
---
--- Files are walked in DIFF order rather than note order, so the agent reads
--- them in the order they appear in the change. A file with no notes writes no
--- header — an empty `## src/foo.rs` is a heading about nothing.
---
--- Notes on a file that is not in the diff any more are NOT dropped silently:
--- v1 omits them, and this counts them at the end instead. Somebody typed them.
function M.notes_markdown(parse, written, range)
  if #written == 0 then
    return nil
  end
  local out = { "# Code review" }
  -- What the notes are ABOUT, when it is not the whole branch. A review of one
  -- commit that reads `new:12` and does not say which commit is a set of line
  -- numbers with no referent — the agent is standing in the worktree, where
  -- `new:12` means HEAD unless it is told otherwise.
  if range and range ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "Reviewing `" .. range .. "`."
  end

  for _, file in ipairs(parse.files) do
    local wrote_header = false
    for _, note in ipairs(written) do
      if note.path == file.path then
        if not wrote_header then
          out[#out + 1] = ""
          out[#out + 1] = "## " .. file.path
          wrote_header = true
        end
        local where = note.kind == "line" and (note.side .. ":" .. tostring(note.line)) or "file"
        out[#out + 1] = string.format(
          "- **[%s]** (%s) %s",
          notes.LABEL[note.class] or "Note",
          where,
          note.text or ""
        )
      end
    end
  end

  local wrote_summary = false
  for _, note in ipairs(written) do
    if note.kind == "review" then
      if not wrote_summary then
        out[#out + 1] = ""
        out[#out + 1] = "## Summary"
        wrote_summary = true
      end
      out[#out + 1] =
        string.format("- **[%s]** %s", notes.LABEL[note.class] or "Note", note.text or "")
    end
  end

  local orphans = notes.orphans(parse, written)
  if #orphans > 0 then
    out[#out + 1] = ""
    out[#out + 1] = string.format("## Notes on files no longer in this diff (%d)", #orphans)
    for _, note in ipairs(orphans) do
      out[#out + 1] = string.format(
        "- **[%s]** (%s) %s",
        notes.LABEL[note.class] or "Note",
        note.path or "?",
        note.text or ""
      )
    end
  end

  return table.concat(out, "\n")
end

--- The whole review as markdown.
---
--- `at` is the cursor's logical row; when it sits inside a hunk that hunk is
--- quoted, which is what makes the export answer "look at THIS" rather than
--- "look at everything".
function M.markdown(session, parse, at, reviewed, written, range)
  -- With notes, THEY are the review: v1 sends the comments and nothing else,
  -- because the agent is standing in the worktree and can read the code. The
  -- file list and the quoted hunk below are what this pane sends when there are
  -- no notes yet — "here is what changed" rather than "here is what I think".
  if written and #written > 0 then
    return M.notes_markdown(parse, written, range)
  end
  local out = {}
  out[#out + 1] = "Code review of " .. (session and session.name or "this session")
  out[#out + 1] = "(" .. (range or M.range(session)) .. ")"
  out[#out + 1] = ""

  local files = parse.files
  if #files == 0 then
    out[#out + 1] = "No changes."
  else
    out[#out + 1] = "Changed files:"
    for _, file in ipairs(files) do
      local mark = reviewed and reviewed[file.path] and " (reviewed)" or ""
      out[#out + 1] = string.format("- `%s` +%d -%d%s", file.path, file.added, file.removed, mark)
    end
  end

  local path, hunk = quote_hunk(parse, at)
  if hunk and hunk ~= "" then
    out[#out + 1] = ""
    out[#out + 1] = "Looking at `" .. path .. "`:"
    out[#out + 1] = ""
    out[#out + 1] = "```diff"
    out[#out + 1] = hunk
    out[#out + 1] = "```"
  end

  if not parse.done then
    out[#out + 1] = ""
    out[#out + 1] = "(the diff was still being read; this covers what had been read)"
  end

  return table.concat(out, "\n")
end

--- A one-line summary for the status band after a send.
function M.summary(parse)
  local added, removed = 0, 0
  for _, file in ipairs(parse.files) do
    added = added + file.added
    removed = removed + file.removed
  end
  return #parse.files, added, removed
end

M.len = rows.len

return M
