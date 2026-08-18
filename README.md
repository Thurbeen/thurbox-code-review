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

The same key takes you back out, and so does `Esc`. Neither names a pane to
return to: `command("focus", { toggle = true })` reads the kernel's own memory of
where focus came from, and an `Esc` this pane does not claim is answered by the
kernel the same way. Which pane you return to is your arrangement's business, not
this plugin's.

It asks for **no capabilities**. There is no `run`, no `program`, no filesystem:
everything it draws comes from `thurbox.diffs`, which the kernel computes on a
worker. Nothing to trust, nothing to grant.

It needs a v2 plugin kernel from 2026-08-18 or later: `store.selected`-driven
diffs and `base_branch` on the session row (`5c7be55`), `status` / `old_path` /
`raw_bytes` on a published diff (`cf06886`), `command("focus", { toggle })`
(`feaca48`), and a file list built independently of the capped body (`962aef7`) —
which the pane relies on, since it joins the list to the body **by path**.

## Keys

| | |
|---|---|
| `Ctrl+X` / `F7` | open the review — and, pressed again, leave it (global; `Ctrl+X` passes through to a focused agent, which is why the F-key exists) |
| `j` `k` `↑` `↓` | move by one logical row |
| `PgUp` `PgDn` `g` `G` | page, top, bottom |
| `⇥` `⇧⇥` | next / previous file, walking the **list** — which reaches files whose patch the cap cut |
| `[` `]` | previous / next hunk |
| `h` `l` `←` `→` | scroll the body horizontally (the gutter stays pinned) |
| `v` | side by side, or unified |
| `w` | soft-wrap long lines (unified only) |
| `f` | show or hide the changed-files list |
| `/` then `↵` | find in the diff, then keep it and stop typing |
| `n` `N` | next / previous match |
| `m` | mark the current file seen (**transient** — see below) |
| `r` | recompute the diff |
| `e` | send this review to the session's agent |
| `Esc` | close the find bar, or go back where you came from |
| `c` `s` | comment / summarise — **declared, and not built**; see `KERNEL-GAPS.md` |

`r` is refresh rather than v1's mark-reviewed, because `r` is refresh in every
other pane and a chord that means two different things depending on where you
are standing is worse than one spelled differently here. Marking is `m`.

`v`, `w`, `f` and the syntax switch are the **same** four settings you see in
`Ctrl+,` → Plugins — the key writes the setting rather than shadowing it, so the
modal always shows what the keys did and resetting it there works.

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

**D3 held: the body needed no new node kind**, and side-by-side is the proof
rather than the exception. Two columns with one selectable row spanning both are
two run-groups and a divider inside one line of cells — the plugin owns the
geometry, so the arithmetic is its own. Everything here is `text`, `box` and
`surface`. There are still four, and `tests/run.sh --render` asserts it
mechanically.

The body is **clickable** through the same primitive: a `surface` takes an `id`
like any node, the kernel records its rect, and a click arrives with `x`/`y`
inside it. The pane resolves that to a logical row from the map it drew — which
it can, because it decided where every row went. Per-line identity in the node
tree was never the only way to be clickable.

Colour is roles only — `diff_added`, `diff_removed`, `diff_added_bg`,
`diff_removed_bg`, `branch_name`, `selection_*` — so the pane is themed by all
36 presets, and by any theme you wrote, without this file knowing they exist.

**The code is coloured too**, by a small language-agnostic lexer in
`lib/syntax.lua` — comments, strings, numbers, keywords and capitalised names.
With it on, the add/remove signal moves entirely to the **sign column and the
row's background tint** and the foreground belongs to the code, because a line
cannot carry two meanings in one colour. It costs about 0.75 of one instruction
batch per frame and does not grow with the diff, since only the visible lines are
ever lexed. Turn it off in `Ctrl+,` → Plugins.

There is no syntax palette to draw on — no `syntax_keyword` — so the classes
borrow roles that already exist, mapped exactly as v1 mapped them. The cost of
that is real and worth knowing: on a theme where `branch_name` and `diff_added`
resolve to the same colour, a string inside an added line matches its `+` sign.

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
| `truncated` | a banner counting what is missing — "77 of 400 changed files are shown (4.0 of 21.1 MB)" |

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

`KERNEL-GAPS.md` states the exact read and command that would close comments, and
the smaller gaps ranked by what using the pane actually made me want.

## Absent because there is nothing, or because it has not happened yet

One rule, in three places, and worth stating because the second and third read as
inconsistency otherwise:

| | |
|---|---|
| the kernel | `ready` with no files is "nothing changed"; `pending` is "not yet". One is a static line, the other animates |
| the file list | a file whose **patch was cut** is muted and not a click target — there is nothing behind it. A file the **parse has not reached** stays clickable, and the click is honoured the moment it arrives |
| a binary file | listed with **zero** counts rather than dropped: it changed, and `--numstat` simply has nothing to count |

The middle row is the one that bites. The kernel lists every changed file and caps
only the patch, so on a large diff the list is complete while the body is not —
the banner says which ("the patch is capped: 77 of 400 changed files are shown").
Those extra files are real and reachable: **the list has a cursor of its own**,
and `⇥` walks it. Where the body can follow it does, and the two stay in step;
where it cannot, only the list moves and lands on a muted row. Any movement of
the body puts the list back to following it, so the two can never silently
disagree. `m` marks whatever the list is on, so a file you had to read elsewhere
can still be ticked off.

## Developing

```bash
export THURBOX_REPO=/path/to/a/thurbox/checkout   # both test scripts need one

selene .                      # the sandbox contract, statically
stylua --check .
thurbox-cli plugin check      # loads the interface the way thurbox does
tests/run.sh                  # the pure modules, under a real Lua
tests/run.sh --render         # the pane's own node tree
tests/run.sh --measure        # the cost, in the kernel's own unit
tests/render-proof.sh         # the pane actually painting, in a real thurbox
```

`THURBOX_BIN` points `render-proof.sh` at a *snapshot* of the binaries instead of
the checkout's `target/debug`. Worth using: a checkout is a live working tree, and
a rebuild during a run replaces the binary underneath it.

Three layers, because each catches what the one below cannot:

- **`plugin check`** loads the interface but never calls `render`, so it cannot
  tell a pane that draws from a pane that throws.
- **`tests/run.sh --render`** calls `render` against a faked snapshot and asserts
  on the node tree — including, mechanically, that every node kind is one of the
  four. A screenshot shows *what* was painted; this shows *why*.
- **`tests/render-proof.sh`** stands up a hermetic thurbox in a tmux pane with
  real sessions, worktrees and base branches, drives it with keys, and captures
  the frames.

Between them they found every bug this pane has had: the scrollbar's missing `▼`,
a footer that advertised a bare `e` with no label, a files list that printed
`src/` twice, a search box that refreshed the diff when you typed the `r` in
"greet", and file rows that went dead while a large diff was still parsing.

The middle layer exists because a capture once *misled* me — a torn frame, top
border from one paint and bottom from the one before, that looked like the pane
choosing the wrong footer. Captures are evidence about pixels, not about
decisions.

Both scripts write only under `$XDG_CACHE_HOME` and a temp directory; nothing
generated lands in this working copy, because a dirty tree is what makes
`plugin update` refuse to move.
