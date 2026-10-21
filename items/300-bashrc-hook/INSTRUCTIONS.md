# 300-bashrc-hook: runbook (for a person or the daily agent)

Healthy = `/workspace/bin/restore-hook.sh` is executable and `~/.bashrc` contains the kit's 3-line auto-restore hook block
(`[ -r /workspace/bin/restore-hook.sh ] && . /workspace/bin/restore-hook.sh` between `# >>> box auto-restore >>>` and
`# <<< box auto-restore <<<`), byte for byte as `install.sh` writes it. A computer update can reset `~/.bashrc`; then nothing
launches restore-all until the daily routine. `restore` copies `bin/restore-hook.sh` into `/workspace/bin/` and runs
`install.sh --hook-only` from the clone in `state/kit-source`. A failure (clone missing, unbalanced markers) alerts the owner.
Never edit anything outside the markers.
