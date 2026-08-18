# thurbox-code-review

A code-review pane for thurbox's v2 plugin interface: the diff of a session's
worktree against its base branch, reviewable without leaving the TUI.

v1 shipped this natively — 1,844 lines of rendering and 2,610 of state — and it
was deleted with `src/ui`. This is the plugin that pays it back, and it is the
first consumer of `thurbox.diffs` anywhere.

```text
╭ Code review ──────────────────────────────── main..HEAD  +8 -4 ╮
│docs/                 │  D docs/old.md  +0 -1                   │
│   D old.md +0 -1     │@@ -1 +0,0 @@                            │
│   R renamed.md +1 -0 │ 1   - to be deleted                     │
│src/                  │  R docs/notes.md → docs/renamed.md +1 -0│
│   A added.txt +1 -0  │@@ -1,2 +1,3 @@                          │
│ ✓ M one.lua +4 -2    │ 1  1  # Notes                           │
│src/deep/nested/      │ 2  2  first                             │
│   M two.rs +2 -1     │    3+ second                            │
╰ j/k move ⇥ file [ ] hunk / find w wrap m seen r refresh e send ╯
```

## Install

```bash
thurbox-cli plugin install git+https://github.com/<you>/thurbox-code-review
```

**No `layout.lua` edit.** The pane occupies the `center` switch slot beside the
agent's terminal and declares a pill, so the action band offers it the moment it
is installed. Press `Ctrl+X` or `F7` — v1's chords, unbound in v2 until now.

It asks for **no capabilities**. There is no `run`, no `program`, no filesystem:
everything it draws comes from `thurbox.diffs`, which the kernel computes on a
worker. Nothing to trust, nothing to grant.

It needs a kernel with `store.selected`-driven diffs, `base_branch` on the
session row, and `command("diff", …)` — all three landed in the v2 plugin kernel
on 2026-08-18.

## Keys

| | |
|---|---|
| `Ctrl+X` / `F7` | open the review (global; `Ctrl+X` passes through to a focused agent) |
| `j` `k` `↑` `↓` | move by one logical row |
| `PgUp` `PgDn` `g` `G` | page, top, bottom |
| `⇥` `⇧⇥` | next / previous file |
| `[` `]` | previous / next hunk |
| `h` `l` `←` `→` | scroll the body horizontally (the gutter stays pinned) |
| `w` | soft-wrap long lines |
| `f` | show or hide the changed-files list |
| `/` then `↵` | find in the diff, then keep it and stop typing |
| `n` `N` | next / previous match |
| `m` | mark the current file seen (**transient** — see below) |
| `r` | recompute the diff |
| `e` | send this review to the session's agent |
| `Esc` | close the find bar, or go back to the agent |
| `c` `s` | comment / summarise — **declared, and not built**; see `KERNEL-GAPS.md` |

`r` is refresh rather than v1's mark-reviewed, because `r` is refresh in every
other pane and a chord that means two different things depending on where you
are standing is worse than one spelled differently here. Marking is `m`.

Two settings appear in `Ctrl+,` → the Plugins tab: whether the pane **starts**
wrapped, and whether it starts with the files list shown. `w` and `f` override
for the session you are in.

## The one rule

**One logical diff row is one selectable unit.** Wrapping expands *visual* rows
only; the cursor, the scroll anchor, the scrollbar thumb and every hitbox stay
indices into one flat logical list. That is v1's rule and it is what makes a
comment anchor mean anything later. `lib/rows.lua` is the only file that knows a
row can occupy more than one line — deliberately, because the moment those two
ideas share a variable the rule is gone.

## How it is built

Two shapes in one pane, which is design.md **D2**:

- the **changed-files list is a tree** — `text` rows carrying `id` and
  `role = "row"`, so they are selectable, clickable and decoratable by a pane
  that has never heard of this one;
- the **diff body is a surface** — cells positioned by character measurement
  against the width the kernel resolved, so wrapping, horizontal scrolling and
  colouring are decisions this plugin makes from `ctx.width`.

**D3 held: the body needed no new node kind.** Everything above is `text`, `box`
and `surface`. There are still four.

Colour is roles only — `diff_added`, `diff_removed`, `diff_added_bg`,
`diff_removed_bg`, `branch_name`, `selection_*` — so the pane is themed by all
36 presets, and by any theme you wrote, without this file knowing they exist.

The parser is **incremental**: it reads a bounded number of lines per frame and
the pane draws what exists so far. `MEASUREMENTS.md` records why, and what was
measured to pick the number.

Five states, each drawn differently, because the kernel is explicit that they
must be distinguishable:

| | |
|---|---|
| no entry in `thurbox.diffs` | `⠴ Asking for the diff…`, animated |
| `pending` | `⠦ Building diff…` + the range, animated |
| `failed` | the kernel's own reason, in the `danger` role |
| `ready`, no files | a **static** `No changes` + the range that was diffed |
| `truncated` | a banner that stays up whatever else is shown |

The first two move and the fourth does not, which is what the eye actually
reads. A slow diff must never look like a clean worktree.

## What is missing, and why it is missing rather than faked

**Comments and review marks do not persist.** The kernel still has the storage
v1 used — `storage::review`, `review_comments` and `review_marks`, schema v38,
keyed on the write-once `sessions.base_branch` — but none of it is published to
Lua and there is no command to write one. So `c` and `s` are declared, appear in
`F1`, and say what is missing instead of pretending. `m` keeps its marks in
`state`, which survives a reload and **not** a restart; the footer calls them
"seen" rather than "reviewed" for that reason.

`KERNEL-GAPS.md` states the exact read and command that would close it, plus the
two smaller gaps: no plugin can put text on the clipboard (v1's `y`), and
`thurbox.diffs` publishes one diff per session with no way to ask for another
target (v1's `t` — branch / working / per-commit).

## Developing

```bash
selene .                 # the sandbox contract, statically
stylua --check .
thurbox-cli plugin check # loads the interface the way thurbox does
tests/run.sh             # the pure modules, under a real Lua
tests/render-proof.sh    # the pane actually painting, in a real thurbox
```

`plugin check` never calls `render`, so it cannot tell a pane that draws from a
pane that throws. `tests/render-proof.sh` is what does: it stands up a hermetic
thurbox in a tmux pane with real sessions, real worktrees and a real base branch,
drives it with keys, and captures the frames. Every bug in this pane's history
was found there and not by `check` — the scrollbar's missing `▼`, a footer that
advertised a bare `e` with no label, a files list that printed `src/` twice, and
a search box that refreshed the diff when you typed the `r` in "greet".

Both scripts write only under `$XDG_CACHE_HOME` and a temp directory; nothing
generated lands in this working copy, because a dirty tree is what makes
`plugin update` refuse to move.
