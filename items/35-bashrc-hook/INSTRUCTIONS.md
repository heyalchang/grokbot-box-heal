# 35-bashrc-hook
Healthy = `~/.bashrc` contains the kit's auto-restore hook block, byte for byte as `install.sh` writes it (the block between
`# >>> box auto-restore >>>` and `# <<< box auto-restore <<<`). A computer update can reset `~/.bashrc`; then nothing launches
restore-all until the daily routine. `restore` runs `install.sh --hook-only` from the clone in `state/kit-source`.
NO_AGENT is set: a failure (clone missing, unbalanced markers) alerts the owner. Never edit anything outside the markers.
