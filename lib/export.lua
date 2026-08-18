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

--- The whole review as markdown.
---
--- `at` is the cursor's logical row; when it sits inside a hunk that hunk is
--- quoted, which is what makes the export answer "look at THIS" rather than
--- "look at everything".
function M.markdown(session, parse, at, reviewed)
  local out = {}
  out[#out + 1] = "Code review of " .. (session and session.name or "this session")
  out[#out + 1] = "(" .. M.range(session) .. ")"
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
