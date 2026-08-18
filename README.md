# thurbox-code-review

A code-review pane for thurbox's plugin interface: the diff of a session's
worktree against its base branch, reviewable without leaving the TUI.

v1 shipped this natively and it was deleted with `src/ui`; it is the largest
single thing v2 owes v1. This is the plugin that pays it back.

Install:

    thurbox-cli plugin install git+<this repo>

Status: in development.
