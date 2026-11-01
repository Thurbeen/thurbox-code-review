# thurbox-code-review

Code review inside [thurbox](https://github.com/Thurbeen/thurbox), as a third tab
of the agent pane: **Agent / Shell / Review**. The Review tab shows the diff of a
session's worktree against its base branch. You can fold files, mark them seen,
search, write notes on lines, and send the notes to the session's agent.

![The Review tab beside Agent and Shell, in thurbox's Doom theme: F8 and F7 switch tabs, Ctrl+H and Ctrl+L walk past it, a note is written on a line and sent to the agent](media/demo.gif)

A plugin cannot add a tab to a pane it does not own, so this repository ships
**its own agent pane**: thurbox's `ui/plugins/20_agent.lua` with the Review tab
added. It **replaces** the bundled agent pane, and it cannot be combined with
another fork of that pane.

## Install

1. **Check the version.** `thurbox-cli version` must print 2.35.0 or later (CI
   tests v2.35.2). Releases back to v2.25.0 still load the pane, without
   v2.35's focus frame.
2. **Install the plugin.** This clones the repository into your interface
   directory and records it in `plugins.toml`. Nothing is run.

   ```bash
   thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-code-review
   ```

   Or add the entry to `plugins.toml` yourself and run `thurbox-cli plugin sync`:

   ```toml
   [[plugin]]
   src = "git+https://github.com/Thurbeen/thurbox-code-review"
   file = "thurbox-code-review/plugins/20_agent.lua"
   ```

3. **Remove the bundled agent pane.** No upgrade writes it back.

   ```bash
   rm "$(thurbox-cli plugin dir --text | head -1)/plugins/20_agent.lua"
   ```

4. **Check that exactly one agent pane loads.** `thurbox-cli plugin check`
   should list `agent` once. If it lists `agent, agent`, step 3 was skipped.
5. **Turn it on if it is off.** In thurbox: `Ctrl+,` (or `F6`) → `]` → `j`/`k`
   to `thurbox-code-review/plugins/20_agent.lua` → `space`.
6. **Optionally, grant `run`** on that same row with `t`. Without it the review
   still shows the kernel's diff. With it, `t` in the review can also show
   uncommitted changes and single commits, by running `git`.
7. **Open the Review tab** with `F7`, a click on its chip, or `Ctrl+P` → `review`.

To update: `thurbox-cli plugin update`. To remove:
`thurbox-cli plugin remove thurbox-code-review/plugins/20_agent.lua`, then bring
back thurbox's own pane: `Ctrl+,` → `]` → `plugins/20_agent.lua` → `r`.

## Keys

On the Review tab. On the Agent and Shell tabs these letters go to the terminal.

| Key | Action |
|---|---|
| `F7` | show the Review tab, or go back to Agent (`Ctrl+X` too, from outside the agent pane) |
| `j` `k` `↑` `↓` | move one line |
| `d` `u`, `PgDn` `PgUp` | scroll half a page, a page |
| `g` `G` | top, bottom |
| `⇥` `⇧⇥` | next / previous file |
| `[` `]` | previous / next hunk |
| `h` `l` `←` `→` | scroll sideways |
| `v` | side by side, or unified |
| `w` | soft-wrap long lines |
| `f` | show or hide the changed-files list |
| `/`, `n` `N` | find, next / previous match |
| `↵` | fold or unfold this file |
| `m` | mark this file seen |
| `t` | review the branch, the working changes, or one commit |
| `r` | recompute the diff |
| `c` | note on this line or file |
| `s` | note on the whole review |
| `x` `Del` | delete the note under the cursor |
| `e` | send the notes to the agent |
| `Esc` | close the search, picker or note, or go back to Agent |

Notes and seen marks are kept until thurbox quits. They survive an `F10` reload,
not a restart.

## Configuration

Under the agent pane in `Ctrl+,` → Plugins:

| Setting | Default | What it does |
|---|---|---|
| `review_side` | off | start side by side (`v`) |
| `review_wrap` | off | start with long lines wrapped (`w`) |
| `review_files` | on | show the changed-files list (`f`) |
| `review_syntax` | on | colour the code, not only the change |

`code_review = false` under thurbox's `[features]` turns the Review tab off, the
way `shell_pane = false` turns off Shell.

## More

- [docs/guide.md](docs/guide.md): troubleshooting, upgrading from v0.1.0, review
  targets, how it is built, keeping the fork current, and developing.
- [KERNEL-GAPS.md](KERNEL-GAPS.md): what thurbox would need to change to close
  this plugin's gaps.
- [MEASUREMENTS.md](MEASUREMENTS.md): what the review costs per frame.

## Licence

MIT. See `LICENSE`.
