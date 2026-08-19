-- What the review is OF, and where the answer comes from.
--
-- ── Two sources, and the one rule that keeps them from disagreeing ──────────
--
-- v1 reviews three things: the branch (`<base>..HEAD`), the uncommitted working
-- changes, and a single commit. The kernel computes exactly ONE of those — the
-- branch when a session has a base, the working changes when it does not — so
-- the other two have to be asked for, and `run` is the only door.
--
-- That is a second source for a thing that already has one, which is the fault
-- worth naming before writing the code: a pane that reports "4.0 of 21.1 MB" for
-- one target and something differently-shaped for another is worse than a pane
-- with no picker. The rule that avoids it is that **this module's only output is
-- an entry in `thurbox.diffs`' exact shape** — `state`, `files`, `body`,
-- `truncated`, `raw_bytes` — and everything downstream reads that and cannot
-- tell which source produced it. The pane has six uses of an entry and none of
-- them changed.
--
-- Where the two sources genuinely differ, they say so rather than being papered
-- over:
--
--   * **The cap.** The kernel cuts a body at 4 MiB (`kernel::diff::MAX_DIFF_BYTES`);
--     a run's stdout is cut at 256 KiB (`kernel::runs::OUTPUT_CAP`), sixteen times
--     smaller. So the entry carries `cap`, and the banner names the number that
--     actually applied. A commit diff is normally kilobytes and a branch diff can
--     be megabytes, which is why this is survivable — but it is not hidden.
--   * **The line boundary.** The kernel cuts on one. A run does not, so the last
--     line of a truncated capture is half a line and is DROPPED here — otherwise
--     the parser would read a truncated `+foo` as a real addition.
--   * **Trust.** The kernel's diff needs no capability. These need `run`, which
--     is off until granted, so the picker degrades to "the target the kernel
--     serves" and says why rather than offering choices that would fail.
--
-- ── Retention, which is a real cost and is not hidden either ────────────────
--
-- Run answers are keyed `(plugin, key)` and evicted only when the plugin goes
-- (`runs.rs::retain_plugins`). The key here names the target, because it has to:
-- one key reused across targets would serve the previous commit's diff while the
-- new one was still running, and there is no generation counter published to tell
-- them apart. So visiting N commits retains up to N x 256 KiB for the life of the
-- process — 30 commits is ~7.5 MB against a 256 MiB limit.
--
-- It buys something real: going back to a commit you already read is instant
-- rather than another `git show`. It is recorded in KERNEL-GAPS.md all the same.

local M = {}

--- The kernel's cap on one stream of a run's output, `kernel::runs::OUTPUT_CAP`.
--- Not raisable by a plugin; named here so the banner can be honest about which
--- cap cut the body.
M.RUN_CAP = 256 * 1024

--- How many commits the picker offers. v1 lists the whole of `<base>..HEAD`
--- without a bound; this stops at a number, because the list is drawn every
--- frame and a branch with ten thousand commits on it is a pane that stops
--- scrolling smoothly for a list nobody reads past the top of.
M.MAX_COMMITS = 200

--- How long an answer stays fresh, by target.
---
--- A commit's diff is IMMUTABLE — `git show <sha>` will say the same thing in an
--- hour — so re-running it on a timer is pure waste, and the ttl is an hour.
--- Working changes are the opposite: they change while you look at them, and five
--- seconds is close enough to live without a `git diff` per frame. `r` overrides
--- both, which is what a refresh key is for.
local TTL = { commit = 3600, working = 5, branch = 30, log = 30 }

-- ── what a target is ────────────────────────────────────────────────────────
--
-- Held in `state` as a STRING rather than a table: `state` round-trips through
-- the kernel's own value type, and a flat key is one less thing to be wrong
-- about for a value that is three words long.

--- `nil` means "whatever the kernel computes", which is the resting state and the
--- only one that needs no capability.
function M.key(target)
  if not target then
    return "default"
  end
  if target.kind == "commit" then
    return "commit:" .. (target.sha or "")
  end
  return target.kind
end

local function from_key(key)
  if type(key) ~= "string" then
    return nil
  end
  local sha = string.match(key, "^commit:(%x+)$")
  if sha then
    return { kind = "commit", sha = sha }
  end
  if key == "branch" or key == "working" then
    return { kind = key }
  end
  return nil
end

--- A key naming a session AND what it is showing.
---
--- The separator lives HERE rather than at the two call sites that need it: the
--- pane keys per-review state by it and the test harness has to clear by it, and
--- a private separator spelled out in three files is a thing that changes in two
--- of them.
function M.scope(id, held)
  return id .. "\1" .. M.key(held)
end

--- The target in force for a session, or `nil` for the kernel's own.
function M.of(state, id)
  return from_key(state["target:" .. id])
end

function M.set(state, id, target)
  state["target:" .. id] = target and M.key(target) or nil
end

--- Does the KERNEL already compute this target? Then it is served for free, with
--- the kernel's own cap and no capability — and the picker is drawing a choice
--- rather than a fork in the code.
function M.kernel_serves(session, target)
  if not target then
    return true
  end
  if target.kind == "branch" then
    return session.base_branch ~= nil
  end
  if target.kind == "working" then
    return session.base_branch == nil
  end
  return false
end

--- The target `nil` actually MEANS, for this session.
---
--- `nil` is "whatever the kernel computes", which is the branch when a session
--- has a base and the working changes when it does not. The picker offers those
--- two by name, so without this the dot marking the target in force marked
--- nothing at all — `default` matched no row — and `t` opened on `working`
--- whatever you were looking at. Found in a real frame, where the picker listed
--- the branch as `ready` and left it unmarked.
function M.concrete(session, held)
  if held then
    return held
  end
  return { kind = session.base_branch and "branch" or "working" }
end

--- Do two targets name the same review, for this session?
function M.same(session, a, b)
  return M.key(M.concrete(session, a)) == M.key(M.concrete(session, b))
end

--- What the title bar says the review is of. v1's `ReviewTarget::label`, with its
--- wording, and with the range spelled out because that is the thing a reviewer
--- checks before believing what is on screen.
function M.label(target, session, commits)
  local base = session and session.base_branch
  if not target then
    return base and (base .. "..HEAD") or "uncommitted changes"
  end
  if target.kind == "branch" then
    return (base or "base") .. "..HEAD"
  end
  if target.kind == "working" then
    return "uncommitted changes"
  end
  for _, commit in ipairs(commits or {}) do
    if commit.sha == target.sha then
      return target.sha .. " " .. commit.subject
    end
  end
  return target.sha or "?"
end

-- ── asking git ──────────────────────────────────────────────────────────────

--- Single-quote for `sh -c`, which is what a run's command line is parsed by.
---
--- Branch names reach here from the kernel and shas from our own `git log`, so
--- neither is user input in the usual sense — but a branch name may legally
--- contain a quote, and a command line built by concatenation that is right for
--- every name anybody has tried is the shape of the bug found later.
local function quoted(text)
  return "'" .. string.gsub(tostring(text or ""), "'", "'\\''") .. "'"
end

--- `-c core.quotepath=false` for the reason `git::run_diff` gives: git otherwise
--- C-quotes a non-ASCII path (`"caf\303\251.rs"`), and notes and marks are keyed
--- on the path, so the quoted form would anchor them to a file that does not
--- exist.
local GIT = "git -c core.quotepath=false"

--- Untracked files the working diff will show a patch for, before it stops.
---
--- `git diff --no-index` takes exactly two paths, so an untracked file costs a
--- process — and a worktree with an unignored `target/` or `node_modules` would
--- otherwise cost thousands, half of which the 30-second timeout would kill,
--- leaving a truncated capture that parses as a perfectly good short diff. The
--- bound is here so that outcome is a SENTENCE on screen instead.
M.MAX_UNTRACKED = 200

--- The shell that walks the untracked files, given what to run for each.
---
--- Why a loop at all: `git diff HEAD` does not see a file git has never been
--- told about, and "uncommitted changes" that omit the three files the agent
--- just wrote is the wrong answer to the question the target is asking. v1 had
--- this gap too (`git::diff_working_on` is `diff --no-color HEAD`), and so does
--- the kernel's own working diff — recorded in KERNEL-GAPS.md, because the pane
--- can only fix the half it runs itself.
---
--- Why not the one-process alternative: a scratch `GIT_INDEX_FILE` plus
--- `git add -A` gives the whole thing — untracked, renames, odd filenames — in a
--- single `git diff --cached HEAD`. It also **writes loose objects into the
--- repository being reviewed**, and it would do so every few seconds while an
--- agent edits in that worktree. A review pane reads; it does not write to the
--- thing it is reading. Measured: three new objects for three changed files.
---
--- `IFS` is set to a newline so a path with SPACES survives word splitting. A
--- path containing a literal newline does not, and that file is missing from the
--- review — the one case this does not handle, named here rather than discovered.
local function untracked_loop(each)
  return table.concat({
    "IFS='\n'",
    "n=0",
    "for f in $(" .. GIT .. " ls-files --others --exclude-standard); do",
    "  n=$((n+1))",
    '  if [ "$n" -le ' .. M.MAX_UNTRACKED .. " ]; then",
    -- `|| true`: `--no-index` exits 1 whenever the two sides differ, which for a
    -- new file is always. Its failure and its success look the same, so the
    -- status is not information and is discarded here rather than mistaken for
    -- one further up.
    "    " .. each .. ' -- /dev/null "$f" || true',
    "  fi",
    "done",
  }, "\n")
end

--- The marker the file-list command ends with, so Lua learns the untracked TOTAL
--- even when the loop stopped short of it.
---
--- Read from the LAST field only, which is the one this wrote — a path that
--- happened to spell the same thing cannot be last, because the marker is.
local MARKER = "thurbox-untracked"

local function programs(session, target)
  local base = session.base_branch
  if target.kind == "commit" then
    local sha = quoted(target.sha)
    return GIT .. " show --no-color --format= " .. sha,
      GIT .. " show --no-color --format= --numstat --raw -M -z " .. sha
  end
  if target.kind == "working" then
    -- `HEAD` for the tracked half, matching `git::working_diff`: staged and
    -- unstaged together, which is what "what have I not committed" means. Then
    -- every untracked file, which is the half `git diff` cannot be asked for.
    --
    -- `|| exit $?` on the FIRST command only: if the tracked diff fails the
    -- whole answer is wrong and must say so, where a single untracked file
    -- failing is one file missing from a diff that is otherwise correct.
    local head = GIT .. " diff --no-color HEAD"
    local listed = GIT .. " diff --no-color --numstat --raw -M -z HEAD"
    return head .. " || exit $?\n" .. untracked_loop(GIT .. " diff --no-color --no-index"),
      listed .. " || exit $?\n" .. untracked_loop(
        GIT .. " diff --no-color --numstat --raw -M -z --no-index"
      ) .. "\nprintf '\\0" .. MARKER .. ' %s\\0\' "$n"'
  end
  local range = quoted((base or "HEAD") .. "..HEAD")
  return GIT .. " diff --no-color " .. range,
    GIT .. " diff --no-color --numstat --raw -M -z " .. range
end

-- ── reading what git said ───────────────────────────────────────────────────
--
-- Both parses are cached against the OUTPUT STRING itself. A run republishes a
-- fresh Lua string every frame, so the guard is a real comparison — but it is a
-- length check and a memcmp in C, not a pass in Lua bytecode, where re-splitting
-- a quarter of a megabyte into lines every frame would be thousands of `sub`
-- calls a frame for an answer that changes every few seconds at most.

local line_cache = {}
local files_cache = {}
local log_cache = {}

--- Exported so the tests can reach it: this and `parse_files` are the two places
--- git's bytes become the pane's data, and they are worth checking against real
--- captured output rather than only through a rendered pane.
function M.split_lines(text, truncated)
  local out, at, size = {}, 1, #text
  while at <= size do
    local stop = string.find(text, "\n", at, true)
    if not stop then
      -- No trailing newline. If the capture was CUT this is half a line and is
      -- dropped; the kernel cuts on a line boundary and this is how the two
      -- sources come to mean the same thing.
      if not truncated then
        out[#out + 1] = string.sub(text, at)
      end
      break
    end
    out[#out + 1] = string.sub(text, at, stop - 1)
    at = stop + 1
  end
  return out
end

local function lines_of(key, text, truncated)
  local held = line_cache[key]
  if held and held.text == text and held.truncated == truncated then
    return held.lines
  end
  local lines = M.split_lines(text, truncated)
  line_cache[key] = { text = text, truncated = truncated, lines = lines }
  return lines
end

--- NUL-separated fields, as `-z` produces and `parse_changed_files` consumes.
local function fields_of(text)
  local out, at, size = {}, 1, #text
  while at <= size do
    local stop = string.find(text, "\0", at, true) or (size + 1)
    local field = string.sub(text, at, stop - 1)
    if field ~= "" then
      out[#out + 1] = field
    end
    at = stop + 1
  end
  return out
end

--- The changed-file list, in `thurbox.diffs[id].files`' exact shape.
---
--- One command gives both halves: `--raw` records carry the status letter and
--- `--numstat` records carry the counts, and a record starting with `:` is a raw
--- one. The kernel runs `--name-status` and `--numstat` separately and joins them
--- by path (`session::review::parse_changed_files`); this joins the same two
--- things the same way, from one process instead of two, because the raw header's
--- status field is the name-status letter by another name.
---
--- Dispatched PER FIELD rather than in two phases. The first version read every
--- leading `:` record and then treated the rest as numstat, which is the shape
--- `git diff` alone produces — and the working target appends one `--no-index`
--- call per untracked file, so the stream becomes raw, numstat, raw, numstat…
--- and the two-phase reader stopped at the first interleaved header and dropped
--- every untracked file from the list. They were in the body and absent from the
--- list beside it.
---
--- Returns the list, and the untracked TOTAL when the command reported one.
function M.parse_files(text)
  local list = fields_of(text)
  local statuses, out, untracked = {}, {}, nil
  local at = 1

  -- The marker the working command ends with. Read from the last field only,
  -- which is the field this pane wrote.
  --
  -- Compared as TEXT, not matched as a pattern. `thurbox-untracked` contains a
  -- hyphen, and a hyphen in a Lua pattern is a lazy quantifier — so
  -- `string.match(last, "^" .. MARKER .. " (%d+)$")` never matched its own
  -- marker, and the count came back nil with nothing to say why. The same trap
  -- as reading `[▸▾]` as a character class, which is a set of BYTES.
  local prefix = MARKER .. " "
  local last = list[#list]
  if last and string.sub(last, 1, #prefix) == prefix then
    untracked = tonumber(string.sub(last, #prefix + 1))
    if untracked then
      list[#list] = nil
    end
  end

  while at <= #list do
    local field = list[at]
    at = at + 1

    if string.sub(field, 1, 1) == ":" then
      -- `:100644 100644 de98044 d68dd40 R075` — the status is the last token.
      local letter = string.match(field, "([^%s]+)%s*$") or "M"
      local head = string.sub(letter, 1, 1)
      if head == "R" or head == "C" then
        local old, new_path = list[at], list[at + 1]
        at = at + 2
        if not new_path then
          break
        end
        statuses[new_path] = { status = "R", old_path = old }
      else
        local path = list[at]
        at = at + 1
        if not path then
          break
        end
        local status = "M"
        if head == "A" then
          status = "A"
        elseif head == "D" then
          status = "D"
        end
        statuses[path] = { status = status }
      end
    else
      local added, removed, path = string.match(field, "^([^\t]*)\t([^\t]*)\t(.*)$")
      if not added then
        break
      end
      if path == "" then
        -- A rename: the next two records are the old and the new name. `-z` is
        -- what makes that unambiguous, which is why the kernel uses it too. An
        -- untracked file arrives in this shape as well — `--no-index` names
        -- `/dev/null` as its old side — and the new side is what it is called.
        local new_path = list[at + 1]
        at = at + 2
        if not new_path then
          break
        end
        path = new_path
      end
      local known = statuses[path] or {}
      out[#out + 1] = {
        path = path,
        -- `-` for a binary file: it changed, and it has no line counts.
        added = tonumber(added) or 0,
        removed = tonumber(removed) or 0,
        status = known.status or "M",
        old_path = known.old_path,
      }
    end
  end
  return out, untracked
end

local function files_of(key, text)
  local held = files_cache[key]
  if held and held.text == text then
    return held.files, held.untracked
  end
  local list, untracked = M.parse_files(text)
  files_cache[key] = { text = text, files = list, untracked = untracked }
  return list, untracked
end

-- ── the entry ───────────────────────────────────────────────────────────────

local function ask(key, program, session, ttl, refresh)
  -- Every frame, as PLUGINS.md insists: `run` does nothing while the answer is
  -- fresh or while one is already going, so this is a map lookup rather than a
  -- process, and asking once somewhere clever is how a pane shows yesterday's
  -- answer forever.
  run(key, program, { session = session, ttl = ttl, refresh = refresh or nil })
  return (thurbox and thurbox.runs or {})[key]
end

local function failed(reason)
  return { state = "failed", error = reason, source = "run" }
end

--- Why a run did not produce a diff, in git's own words where it has any.
local function why(got)
  local text = (got.stderr or ""):gsub("%s+$", "")
  local first = string.match(text, "^([^\n]*)") or ""
  if got.timed_out then
    return "git took too long"
  end
  if first ~= "" then
    return first
  end
  return "git exited " .. tostring(got.status or "?")
end

--- The diff to draw, whatever it is of, in `thurbox.diffs`' shape.
---
--- `kernel` is `thurbox.diffs[id]` — returned untouched when the kernel already
--- computes the target in force, which is the resting case and the one that needs
--- no capability at all.
function M.entry(session, target, kernel, refresh)
  if M.kernel_serves(session, target) then
    return kernel
  end
  if not run then
    return failed("this target is built by running git — trust the plugin in settings")
  end

  local id = session.id
  local stem = "rv:" .. id .. ":" .. M.key(target)
  local body_program, files_program = programs(session, target)
  local ttl = TTL[target.kind] or 30
  local body = ask(stem .. ":body", body_program, id, ttl, refresh)
  local files = ask(stem .. ":files", files_program, id, ttl, refresh)

  if not body or not files or body.state == "pending" or files.state == "pending" then
    return { state = "pending", source = "run" }
  end
  if body.state == "failed" then
    return failed(body.error or "could not run git")
  end
  if files.state == "failed" then
    return failed(files.error or "could not run git")
  end
  -- The file list is the half that must not be reported as complete when it is
  -- not: the kernel refuses the whole diff when the cheap commands fail, for
  -- exactly this reason, and a list that is short by a hundred files is a pane
  -- that says a change does not exist.
  if not files.ok then
    return failed(why(files))
  end
  if files.truncated then
    return failed("too many changed files to list")
  end
  if not body.ok then
    return failed(why(body))
  end

  local listed, untracked = files_of(stem, files.stdout or "")
  return {
    state = "ready",
    files = listed,
    -- How many untracked files the loop did not reach, so the pane can say so.
    -- Not folded into `truncated`: the PATCH being capped and the LIST being
    -- short are two different incomplete things, and a reviewer needs to know
    -- which one they are looking at.
    untracked_cut = (untracked and untracked > M.MAX_UNTRACKED) and (untracked - M.MAX_UNTRACKED)
      or nil,
    body = lines_of(stem, body.stdout or "", body.truncated == true),
    truncated = body.truncated == true,
    -- Unknown, and left unknown: a cut capture cannot say how big the whole was,
    -- and the banner prints a size only when it has one.
    raw_bytes = nil,
    cap = M.RUN_CAP,
    source = "run",
  }
end

-- ── the commit list ─────────────────────────────────────────────────────────

--- The commits the picker offers, newest first.
---
--- `%p` is in the format because a merge commit shows NO diff under `git show`
--- without `-m`, and a target that draws an empty pane with no explanation is
--- the kind of silence this pane exists to avoid. v1 has the same blind spot;
--- here the picker labels them.
function M.commits(session, refresh)
  if not run then
    return { state = "denied", list = {} }
  end
  local base = session.base_branch
  -- Without a base there is no `<base>..HEAD` to list, and the useful answer is
  -- still "the recent commits" — you can review any of them. v1 offers nothing
  -- here; this offers the same bounded list it would offer with a base.
  local range = base and (quoted(base .. "..HEAD")) or "HEAD"
  local program = GIT
    .. " log --no-color --format=%h%x09%p%x09%s -n "
    .. M.MAX_COMMITS
    .. " "
    .. range
  local key = "rv:" .. session.id .. ":log"
  local got = ask(key, program, session.id, TTL.log, refresh)
  if not got or got.state == "pending" then
    return { state = "pending", list = {} }
  end
  if got.state == "failed" or not got.ok then
    return { state = "failed", error = got.error or why(got), list = {} }
  end

  local held = log_cache[key]
  if held and held.text == got.stdout then
    return held.commits
  end
  local list = {}
  for _, line in ipairs(M.split_lines(got.stdout or "", got.truncated == true)) do
    local sha, parents, subject = string.match(line, "^(%x+)\t([^\t]*)\t(.*)$")
    if sha then
      list[#list + 1] = {
        sha = sha,
        subject = subject,
        -- Two parents named is a merge, and `git show` will draw nothing for it.
        merge = string.find(parents, " ", 1, true) ~= nil,
      }
    end
  end
  local answer = { state = "ready", list = list, truncated = got.truncated == true }
  log_cache[key] = { text = got.stdout, commits = answer }
  return answer
end

--- The commit list if one has already been fetched, WITHOUT asking for one.
---
--- The header names the target, and a commit's name is its subject — but the
--- header is drawn on every frame and the picker is opened on almost none of
--- them, so asking here would run `git log` every 30 seconds for the whole time
--- a commit was on screen. Reading the answer that is already published costs a
--- map lookup and gets the subject whenever the picker has been opened once,
--- which is always, because opening it is how you got here.
---
--- When there is no answer the caller falls back to the sha, which is the fact
--- rather than a guess at the name.
function M.known_commits(session)
  local got = (thurbox and thurbox.runs or {})["rv:" .. session.id .. ":log"]
  if not got or got.state ~= "done" or not got.ok then
    return {}
  end
  local held = log_cache["rv:" .. session.id .. ":log"]
  if held and held.text == got.stdout then
    return held.commits.list
  end
  return {}
end

--- Everything the picker offers, in v1's order: working, branch, then commits.
---
--- A choice the kernel cannot serve and `run` may not either is still LISTED —
--- with `needs_trust` set — because a picker that hides what it cannot do reads
--- as a picker with nothing in it, and the honest answer is that the choice
--- exists and is behind a decision you have already been asked to make.
function M.choices(session, commits)
  local granted = run ~= nil
  local out = {}
  local function add(target)
    out[#out + 1] = {
      target = target,
      needs_trust = not granted and not M.kernel_serves(session, target),
    }
  end
  add({ kind = "working" })
  if session.base_branch then
    add({ kind = "branch" })
  end
  for _, commit in ipairs(commits or {}) do
    out[#out + 1] = {
      target = { kind = "commit", sha = commit.sha },
      commit = commit,
      needs_trust = not granted,
    }
  end
  return out
end

--- Forget what was parsed for a session, so a refresh re-reads it.
function M.forget(session)
  local stem = "rv:" .. session .. ":"
  for key in pairs(line_cache) do
    if string.sub(key, 1, #stem) == stem then
      line_cache[key] = nil
    end
  end
  for key in pairs(files_cache) do
    if string.sub(key, 1, #stem) == stem then
      files_cache[key] = nil
    end
  end
  for key in pairs(log_cache) do
    if string.sub(key, 1, #stem) == stem then
      log_cache[key] = nil
    end
  end
end

--- Exported for the tests: the exact command lines this asks `sh` to run, which
--- are the one part of this module that a Lua test cannot execute and a shell
--- test can.
M.__programs = programs

return M
