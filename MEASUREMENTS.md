# What was measured, and what it changed

The incremental parse in `lib/diff.lua` was designed against the instruction
budget and then measured. The measurement moved the reason for it, which is the
interesting part, so it is written down rather than summarised as a number.

Reproduce with `tests/measure.lua` (see `tests/run.sh`).

## The subject

`git diff main..HEAD` over the thurbox checkout — the real 5.5 MB diff — cut at
the kernel's 4 MiB cap on a line boundary, exactly as `kernel::diff::compute`
cuts it:

```text
99,041 body lines  ->  97,877 logical rows
```

Instructions are counted the way the kernel counts them: a Lua count hook every
100,000 instructions, matching `kernel::host::Budget::arm`. The kernel allows
`INSTRUCTION_BUDGET / 100_000` = **200 batches per call**.

## The parse

| lines per frame | batches | instructions/line | first frame | frames | total |
|---|---|---|---|---|---|
| 2,000 | 2 | 100 | — | 50 | — |
| 4,000 | 4 | 100 | — | 25 | — |
| **8,000** | **8** | **100** | **10.1 ms** | **13** | **127 ms** |
| 16,000 | 17 | 106 | 28.8 ms | 7 | 103 ms |
| 32,000 | 34 | 106 | 39.0 ms | 4 | 156 ms |

Linear at ~100 instructions per line, as a single pass over strings should be.

**The instruction budget was not the binding constraint.** A whole capped diff is
~10M instructions — 99 batches, half of what the kernel allows — so a single-shot
parse would have survived it. What it would not have survived is the frame: 125 ms
of one `render` is two and a half frames of a frozen interface at 20fps.

So `LINES_PER_FRAME = 8000` is chosen on **wall clock**: 10.1 ms leaves the rest
of a 50 ms frame to the render and to every other pane, and a capped diff finishes
in 13 frames — about two thirds of a second, spent showing the part already read
rather than showing nothing.

The budget remains the thing that makes the pane *safe*; the frame is the thing
that makes it *usable*. It was built against the first and is tuned by the second.

## The render

Free, at every shape tried:

| shape | batches |
|---|---|
| 120x40, no wrap | 0 |
| 120x40, wrapped | 0 |
| 40x40, wrapped | 0 |
| 120x200, wrapped | 1 |
| steady frame (parse cache hit + window) | 0 |

Which is the expected shape of the design: the window is bounded by the pane's
height, so it costs the same whether the diff is forty rows or a hundred thousand.

## The same diff, handed over again

Since thurbox v2.5.2 the kernel's diff has an age (5 s), and a stale answer is
replaced in place with no `pending` frame between. The pane used to tell bodies
apart by an epoch that only moved on a non-ready frame, backed by a sixteen-line
sample — which let a line edited anywhere the sample did not look stay on screen
as it was. Bodies are now compared exactly, and only when the published TABLE is
a different one.

Measured on a synthetic 4 MiB diff cut on a line boundary (61,795 lines, 400
files rewritten), against thurbox v2.24.1's interface:

| | batches |
|---|---|
| a new table holding the same lines, the frame it arrives | **2** |
| the frame after (the new table was adopted, so `rawequal`) | **0** |
| a reparse, for comparison | 8 a frame, over 8 frames |

The kernel rebuilds `thurbox.diffs` whenever its data epoch moves, which is
more often than the diff changes, so this is the cost that keeps a republish
from being a reparse.

Re-measured at the same time, the render still costs 0 batches at 120x40 and 1
at 120x200 wrapped, and the steady frame 0 — the numbers above hold on
v2.24.1. The syntax lexer costs **2.40 batches a frame at 120x40** on this
fixture against the 0.50 above: every file here is one 800-line hunk, so the
lookback walks its full 400 lines on every frame. That is the `MAX_LOOKBACK`
bound doing its job on a worst-shaped diff, and another reminder that a
synthetic fixture answers a question about itself.

`tests/measure.lua` swaps the harness's `text.width` for a native call before
measuring. In the VM it is one Rust function, invisible to the count hook; the
Lua stand-in the tests use walks the string, and measuring it read as 3 batches
for a render that is 0.

## Two scans the measurement found, and killed

Both were O(rows) *per frame* — invisible on a normal diff and paid on every one
of the 13 frames of a capped one.

**The gutter width** scanned every row for the largest line number: 12 batches
(1.2M instructions) a frame, for a number the parser already had in its hand. The
parser now keeps `parse.widest` as rows are appended and `rows.gutter_digits` is
O(1). It is still allowed to grow while the parse runs, which is correct — a
gutter frozen at the width the first eight thousand lines needed would misalign
every line after them.

**The find scan** rebuilt the match list whenever the row count changed: 23
batches and 32 ms a frame while a query was open during a parse. Rows are only
ever appended, so the scan now resumes from where it stopped; the whole parse
costs one pass however many frames it takes.

Neither was a bug you could see. Both were found by measuring the thing that had
already been designed, which is the argument for measuring it.

## Listing files without the patch, and a caution about these numbers

Measured while arguing that the changed-files list should not be capped with the
body. Same 22 MB synthetic diff, best of three:

| | |
|---|---|
| `git diff` (full) | 84.8 ms, 22,130,000 bytes |
| `git diff --numstat -M` | 44.5 ms, 12,000 bytes — 400 files, exact counts |
| `git diff --name-status -M` | 2.1 ms, 9,600 bytes — 400 files, M/A/D/R |

The kernel took that shape in `962aef7`. **Do not quote these as a ceiling.**
Measured against thurbox's own 5.5 MB diff on the maintainer's machine the same
two commands cost 190 ms and 138 ms — the fixture here is 400 near-identical
files in one directory, which is close to the best case for git's rename
detection and its diffstat. The trade holds either way (it is a worker, off the
render path, against an expensive command that already ran), but the ratio is a
property of the repository, not of the commands.

That correction is the useful half: a measurement taken on a synthetic fixture
answers a question about that fixture. It was right about the *shape* — listing
is far cheaper than patching — and wrong about the magnitude by roughly 4x.

## What syntax highlighting costs

Per VISIBLE line, so bounded by the pane's height and not by the diff. Measured
over 20 frames against the capped diff, with the lexer off and on:

| shape | off | on | added per frame |
|---|---|---|---|
| 120x40 | 3 batches | 13 | **0.50** |
| 200x60 | 5 batches | 20 | **0.75** |

Three quarters of one batch is 75,000 instructions — about 0.4% of the 200 the
kernel allows a call. It does not grow with the diff, because the window only
ever hands the lexer the forty-odd lines it is about to paint.

That is the number behind the design's claim that highlighting is "a property of
the cells the plugin produces". It is not merely possible without a kernel
change; it is cheap enough that the question never comes up.

## The highlighter, and the version of it that would have killed the pane

Per-language keywords and regions that outlive a line (block comments,
multi-line strings) were added in two steps, and the first one was fatal:

| version | cost on a capped diff |
|---|---|
| walk every row, `string.sub` per byte | **1444 batches** — 7x the 200 the kernel allows |
| walk back to the hunk, `string.find` to jump | 3.80–4.15 batches/frame |
| …with the lookback bounded to 400 lines | **1.30–1.65 batches/frame** |

Three separate mistakes, and they are worth separating because they are the three
ways this kind of code goes wrong:

1. **Scope.** Recording the region state for every row of the parse is O(diff),
   and an editor gets away with it only because it has the whole document and no
   frame deadline. The state is needed for the FORTY lines on screen, so it is
   computed for those, walking back only as far as the enclosing hunk header.
2. **Method.** Testing every byte position against every marker with
   `string.sub` is four allocations per character. `string.find(…, plain)` jumps
   to the next interesting position instead, which is the same algorithm with the
   inner loop deleted.
3. **Worst case.** A hunk is normally tens of lines and can be fifty thousand.
   `MAX_LOOKBACK = 400` caps what one frame can be asked to walk; past it the
   state is taken as code, which is wrong in the direction of plain text.

The lesson is the same one this file already records about the parse: **the
budget is not what bounds this, the frame is** — and an O(diff) pass is a bug
however cheap its inner loop, because the diff is a hundred thousand rows.

## The second source, and what it adds

The target picker takes its diff from `run` rather than from the kernel, which
means the pane is handed a 256 KiB *string* where the kernel hands it a table of
lines. That is a split the kernel's path does not pay:

| | |
|---|---|
| splitting a full 256 KB capture (5,066 lines) | **1 batch** |
| the cache guard, over 20 frames | **0 batches** |
| the changed-file list, one file | **0 batches** |

One batch is 100,000 instructions, paid **once per new answer** — a target switch
or a refresh, not a frame. What keeps it off the frame is the guard, and the
guard is a string comparison of the whole capture: a length check and a memcmp in
C, which is why it does not register in Lua's instruction count at all. That was
the prediction and it is the measurement; if it ever stops being true, the
caching strategy is the thing to revisit rather than the split.

Note the ratio the picker lives under. The kernel's cap is 4 MiB and a run's is
256 KiB, so a run-sourced body is at most one sixteenth of a kernel-sourced one —
and everything measured above about the parse and the render is therefore an
**upper bound** for a picked target, not an estimate of one. The expensive case
is the kernel's, and the kernel's is the default.
