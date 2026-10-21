# 250-gh-auth

GitHub CLI login (optionally checked against `GH_USER` in `/workspace/restore/config.env`), stored persistently in
`/workspace/config/gh` (dir 0700, files 0600, box-owned) and symlinked from `~/.config/gh`.

- `check`: symlink in place, git credential helper for github.com set, `gh api user` works (and matches `GH_USER` if set).
  If `GH_USER` is empty and `/workspace/config/gh` doesn't exist, the item passes (gh auth not in use).
- `restore`: re-creates the symlink and runs `gh auth setup-git`. It never runs `gh auth login`. A missing or rejected token is
  NEEDS HUMAN: the box owner re-runs the device sign-in (see the repo README).
- `NO_AGENT` is set: the runner never calls the Grok agent for this item.
- Never print the token or `hosts.yml`.
- If the `gh` binary itself is gone (it lives outside /workspace), reinstall gh; that is not covered by this item.
