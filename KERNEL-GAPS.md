# What this pane needs from the kernel and does not have

In the order **using** the pane made me want them, which is not the order a
feature list would put them in — see the note on the target picker at the end.
Each names its call site and the smallest change that would do it, so this is a
patch someone could write rather than a wish. None of them is made here: a
kernel change is not a plugin's to make unasked, and faking one in `state` would
look like it worked.

Written against the v2 plugin kernel at `962aef7`.

---

## 1. Review comments are stored and not published — the big one

v1's storage survived the deletion of its UI, complete and unused:

- `src/storage/review.rs` — `add_review_comment`, `list_review_comments`,
  `update_review_comment`, `delete_review_comment`, `toggle_review_mark`,
  `list_review_marks`;
- `src/session/review.rs` — `ReviewComment`, `CommentAnchor` (line / file /
  review), `Classification` (issue / suggestion / note / praise), `Side`,
  `validate_body`, `MAX_REVIEW_BODY_LEN`;
- the `review_comments` and `review_marks` tables, schema v38, keyed on the
  session and on the **write-once** `sessions.base_branch`.

None of it reaches Lua, and there is no command to write one. So this pane can
show a diff and cannot record a thought about it — which is most of what a
review *is*.

**The read.** A `thurbox.review` alongside `thurbox.diffs`, published for the
sessions that have any, from `Database::list_review_comments` /
`list_review_marks`:

```lua
thurbox.review[<session id>] = {
  -- `base_branch` is what the rows are keyed on, so a pane can tell whether the
  -- comments it is about to show belong to the range it is showing. It is on
  -- the session row already, which is the other half of this.
  base_branch = "main",
  comments = {
    { id = 41, file = "src/one.lua", side = "new", line = 12,
      class = "issue", body = "…", created_at = 1750000000000 },
    { id = 42, file = "src/one.lua", class = "note", body = "…" },  -- file-level
    { id = 43, class = "note", body = "…" },                        -- the summary
  },
  marks = { { file = "src/one.lua", hunk = 2 } },   -- hunk absent = whole file
}
```

Shaped like `thurbox.diffs`: absent means "not asked", so a pane can tell
"nothing to show" from "not loaded yet". Served behind a `store.want_review`, as
`want_branches` and `want_content` are, if reading it every frame for every
session is too much.

**The write.** One command, spelled the way `task` and `automation` are:

```lua
command("review", { session = id, action = "comment",
                    file = "src/one.lua", side = "new", line = 12,
                    class = "issue", text = "…" })
command("review", { session = id, action = "edit",   id = 41, text = "…" })
command("review", { session = id, action = "delete", id = 41 })
command("review", { session = id, action = "mark",   file = "src/one.lua", hunk = 2 })
```

`validate_body` already exists and is pure, so the bound and its message are
shared rather than reinvented. `CommentAnchor` is reconstructed from
`(file, side, line)` exactly as `anchor_from_columns` does today: file + line is
a line comment, file alone is a file comment, neither is the summary.

**Why it cannot be faked meanwhile.** `state` survives a reload and not a
restart. A comment that vanishes when you next open thurbox is worse than a
comment you were never offered, because you would have stopped writing it down
anywhere else. So `c` and `s` are declared, listed in `F1`, and say this.

---

## 2. A plugin cannot put text on the clipboard

v1's `y` copied the review as markdown. `Command::Copy` takes `{ session }` and
copies **that session's terminal**, so there is no spelling of "copy this text"
for a plugin at all (`src/kernel/command.rs`, `Command::Copy { session }`).

`e` — send the review to the agent via `command("send", …)` — works today and is
what this pane offers instead. It is not the same thing: `send` types into the
agent, where `y` put the review where the user could paste it into a pull
request.

The change is a `text` field on `copy`, or a `clipboard` command:

```lua
command("copy", { text = "…" })      -- session absent = copy this text
```

The clipboard plumbing is already there (`src/clipboard.rs`); only the route
from Lua is missing.

---

## 3. Nothing says how old a diff is

Real, and realer since `command("diff", …)` exists: after a refresh there is no
way to tell that anything happened, because the diff usually comes back identical
and the only signal is a `pending` flicker lasting ~0.2 s. A `computed_at_ms` on
the entry would let the title say "computed 4m ago". `taken_at_ms` is
snapshot-wide and answers a different question.

A nicety, not a blocker.

---

## 4. `thurbox.diffs` publishes one target per session — BUILT ANOTHER WAY

v1's `t` opened a picker: all branch changes (`base..HEAD`), working changes
(uncommitted), or a single commit. Every git function it needs is still present
and pure —

- `git::diff_against_on(host, worktree, base)`
- `git::diff_working_on(host, worktree)`
- `git::show_commit_on(host, worktree, sha)`
- `git::list_commits_on(host, worktree, base)`

— and `DiffStore` calls the first two already, choosing between them by whether
`base_branch` is set. What is missing is a way for a plugin to *ask* for one.
Retargeting is a kernel read, not a plugin decision, until the store takes a
target.

The change is a target on the request and on the key:

```lua
command("diff", { session = id, target = "working" })   -- or "branch", or a sha
```

with `thurbox.diffs[id].target` published back so a pane can name what it is
showing, and `list_commits_on` behind a `store.want_commits` for the picker.

Note that this generalises `command("diff", { session })`, which exists now and
means "recompute the current target".

**Ranked last on purpose, and I had it higher.** It is on this list because v1
had it, not because using the pane produced the want. Branch-against-base is what
a review *is* and it is the default; working changes are already covered where
they matter, since a session with no `base_branch` falls back to
`diff_working_on`, which is the case v1 needed the picker for; and per-commit is
something I would go to `git` for. It is also the largest of these to build.

### What was built instead, and what it costs

The picker is here now, over `run`, at the owner's call and against the kernel
maintainer's advice — which is recorded because the advice was good and the
trade is real rather than imagined:

> *two sources for one thing, disagreeing about caps, hosts and truncation, with
> the default target coming from one and every other target from the other. A
> pane that reports "4.0 of 21.1 MB" for one target and something `run`-shaped
> for another is worse than a pane with no picker.*

What the implementation does about it, and what remains true anyway:

**One shape.** `lib/target.lua` produces an entry in `thurbox.diffs`' exact form
— `state`, `files`, `body`, `truncated`, `raw_bytes` — and the pane's six uses of
an entry did not change. The kernel still serves the default target, so the
common path is byte for byte what it was and needs no capability.

**The cap really does differ, and is not hidden.** `kernel::runs::OUTPUT_CAP` is
256 KiB against `kernel::diff::MAX_DIFF_BYTES`' 4 MiB — sixteen times smaller. So
the entry carries `cap` and the banner prints the number that applied. A commit
diff is normally kilobytes, which is why this is survivable; a `run`-sourced
*branch* diff of a large repository would be cut far earlier than the kernel cuts
it, and says so.

**The line boundary is repaired here.** The kernel cuts on one; a capture does
not, so the last line of a truncated one is dropped rather than parsed as a real
addition of a line that does not exist.

**And one the kernel still has: `diff_working_on` omits untracked files.**
`git::diff_working_on` is `["diff", "--no-color", "HEAD"]`, which cannot show a
file git has never been told about. That is what a session with **no base
branch** gets by default, and it is what v1 showed too — so an agent that has
just written three new files reports as having changed nothing at all, which is
the most common thing an agent does.

This pane fixes the half it runs itself (the `working` target walks
`ls-files --others --exclude-standard` and diffs each against `/dev/null`), and
cannot fix the kernel's. Worth doing there, and worth doing the same way rather
than with a scratch `GIT_INDEX_FILE` plus `git add -A`: that gets everything in
one process and **writes loose objects into the repository being reviewed**,
which for a pane refreshing every few seconds against a worktree an agent is
editing is a side effect nobody asked for. Measured: three new objects for three
changed files.

**What is still worse than the kernel doing it.** A run answer is keyed
`(plugin, key)` and evicted only when the plugin goes, so visiting N commits
retains up to N x 256 KiB for the life of the process (30 commits is ~7.5 MB
against a 256 MiB limit). The key has to name the target — one key reused across
targets would serve the previous commit's diff while the new one ran, and no
generation counter is published to tell them apart. It buys instant return to a
commit already read. **A kernel-side `DiffStore` keyed on `(session, target)`
would have neither problem**, which is the shape the maintainer described and the
one to build when it is scheduled: this pane would then delete `lib/target.lua`'s
git half and keep its picker.

---

## 6. A capability can only be granted by hand

`run` is absent until the file is trusted, which is the model working. But trust
is written by the Interface tab's `t` and by nothing else — there is no
`thurbox-cli plugin trust <path>`.

The consequence is narrow and real: **a plugin that declares a capability cannot
be exercised by an automated test**. `tests/render-proof.sh` drives a real
thurbox in a real terminal, and to reach the picker at all it has to write the
grant into `$XDG_CONFIG_HOME/thurbox-dev/ui.json` itself — computing the FNV-1a
digest that `kernel::bundled::digest` computes, and depending on the bare-string
grant form that `read_overrides` accepts. That is a test reaching into a private
file format, and it will break silently the day the format moves.

`thurbox-cli plugin trust <file>` (and `untrust`) would fix it, and would also
serve the scripted-setup case — a machine provisioned from a config repository
cannot press `t`. `plugin list --json` already reports `capabilities`, so the
listing half exists.

---

## 7. Small: the two v1 chords are still asserted unbound

`tests/v2_keymap.rs` lists `ctrl+x` and `f7` in `CHORDS_AWAITING_THEIR_PANE` and
asserts they resolve to nothing, "until that pane is back". This pane claims both.

That assertion is over the **bundled** interface, so an installed plugin does not
break it and nothing needs to change to use this. But if this pane is ever
bundled, those two rows are the edit — and the test is right to have been there:
re-pointing a freed chord at something else would have silently changed what a v1
user's muscle memory does.

---

## Already fixed, recorded so the reasoning is not lost

Three defects found while building this pane were fixed in the kernel at
`5c7be55` rather than worked around here. They are worth naming because each was
a *confident wrong answer* rather than a missing feature:

- **the diff was taken against the session's own branch.** `main.rs` passed
  `SessionRow.branch` — the worktree's own branch — as `DiffStore::request`'s
  `base`, so the range was `<own-branch>..HEAD`, which is empty by construction.
  Every worktree-backed session published `state = "ready"` with no files. It
  now passes `base_branch`, which is also published to plugins so a pane can name
  the range it is showing.
- **the request followed the focused pane's session surface.** A pane that shows
  a diff draws no terminal, so it could never be handed the thing it exists to
  show. It follows `store.selected` now.
- **a diff was computed once per session per process.** `DiffStore::invalidate`
  had no caller anywhere in `src`. `command("diff", { session })` now invalidates
  and the next frame recomputes, which is what `r` in this pane does.

Three more, asked for after building against the published shape and fixed in
`cf06886` and `feaca48`:

- **`files` dropped `status` and `old_path`**, which `summarise` already had in
  hand from the parse. The pane re-read the whole body to recover a glyph and a
  rename arrow. Both are published now, and the changed-files list is built from
  the kernel's list rather than from this pane's incremental one — so it is
  complete on the frame the diff arrives, while the body is still being read.
- **`truncated` was a bare bool.** `raw_bytes` — the size before the cut — is
  published now, so the banner says "showing 4.0 MB of 21.1 MB" instead of "some
  changes are not shown". The file *count* is deliberately not offered: counting
  them would mean parsing the whole diff, which is what the cap exists to avoid.
- **the file list was capped along with the body.** `files` was derived from the
  capped text, so a diff past 4 MiB listed only the files whose patch fit — 310
  of 433 on thurbox's own diff, 77 of 400 on a synthetic one, with totals to
  match and nothing on screen to say so. `raw_bytes` had made the banner honest
  about bytes while the list stayed quietly short, which answers a different
  question than the one a reviewer scrolling a list is asking. `files` now comes
  from `--numstat -M -z` plus `--name-status -M -z`, joined on the new path, and
  only `body` is capped.

  Two consequences for this pane, both handled: the list and the body are **two
  different lists** now, so every join between them is by PATH rather than by
  index — an index into one means nothing in the other, and on a capped diff they
  differ by hundreds. And a listed file whose patch was cut is drawn muted and is
  not a click target, because it is the one row that genuinely has nowhere to go.
- **a pane in a switch slot could be entered and not left.** `command("focus",
  { toggle = true })` returns to wherever focus came from, using the same memory
  `Esc` reads. This pane had shipped the `Esc`-to-a-named-sibling version, which
  looks equivalent and is not: the only name it could hard-code is whoever shares
  its slot in the *default* arrangement, and the arrangement is the user's file.
