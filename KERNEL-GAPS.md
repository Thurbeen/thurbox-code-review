# What this pane needs from the kernel and does not have

In the order **using** the pane made me want them, which is not the order a
feature list would put them in — see the note on the target picker at the end.
Each names its call site and the smallest change that would do it, so this is a
patch someone could write rather than a wish. None of them is made here: a
kernel change is not a plugin's to make unasked, and faking one in `state` would
look like it worked.

Written against the v2 plugin kernel at `feaca48`.

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

## 2. The file list is silently truncated with the body

`files` is derived from the **capped** body, so it lists only the files whose
patch fit inside 4 MiB. On a 400-file test repository the pane shows **76 of 400
files**, and totals of `+30610 -30800` where the real ones are ~160,000 each.
`raw_bytes` lets the banner say "4.0 of 21.1 MB", which is about bytes; nothing
says that 81% of the changed files are missing from the *navigation aid*. A
reviewer scrolling the list has no way to know it ends early.

The objection to a file count is that counting would mean parsing the whole diff,
which is what the cap exists to avoid. That is true of the diff **text** and not
of the file **list**: git hands over the whole list without the patch, cheaply.
Measured on that 22 MB diff, best of three:

    git diff (full)            84.8 ms    22,130,000 bytes
    git diff --numstat -M      44.5 ms        12,000 bytes   400 files, exact counts
    git diff --name-status -M   2.1 ms         9,600 bytes   400 files, M/A/D/R

So: **derive `files` from `--numstat -M` + `--name-status -M`, and cap only
`body`.** The list is then always complete and exact, the body stays bounded,
`truncated` keeps meaning what it means, and a pane's header counts stop being a
fraction of the truth. ~45 ms on a worker already spending 85, and 12 KB where
the body is 4 MiB.

It also removes something this pane currently relies on and would rather not:
`files[n]` and the body parse's `files[n]` are the same file only because both
come from one `parse_unified_diff` over the same bytes. Sourced separately they
would not be — so the pane should key on **path**, which is what a comment anchor
will have to do anyway.

---

## 3. A plugin cannot put text on the clipboard

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

## 4. Nothing says how old a diff is

Real, and realer since `command("diff", …)` exists: after a refresh there is no
way to tell that anything happened, because the diff usually comes back identical
and the only signal is a `pending` flicker lasting ~0.2 s. A `computed_at_ms` on
the entry would let the title say "computed 4m ago". `taken_at_ms` is
snapshot-wide and answers a different question.

A nicety, not a blocker.

---

## 5. `thurbox.diffs` publishes one target per session

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

---

## 6. Small: the two v1 chords are still asserted unbound

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
- **a pane in a switch slot could be entered and not left.** `command("focus",
  { toggle = true })` returns to wherever focus came from, using the same memory
  `Esc` reads. This pane had shipped the `Esc`-to-a-named-sibling version, which
  looks equivalent and is not: the only name it could hard-code is whoever shares
  its slot in the *default* arrangement, and the arrangement is the user's file.
