# 200-package-drift: runbook (for a person or the daily agent)

**This item is alert-only: it never installs or removes packages.** This file is for a person or the daily agent whom the box owner
has asked to look at a drift alert. (Paths assume the default workspace `/workspace`.)

## Daily baselines (automatic)
- `/workspace/bin/restore-baseline-snapshot.sh` runs once a day via periodic job `400-baseline-snapshot` (stamp
  `state/job-last-run.400-baseline-snapshot`). Each run:
  1. Captures `dpkg-query -W -f='${Package}\t${Version}\n'` (LC_ALL=C sorted).
  2. Diffs it against the previous baseline. If anything changed, it writes `state/drift/overnight-YYYY-MM-DD.txt`, so drift the new
     baseline absorbs is still on record.
  3. Saves `state/baselines/packages-YYYY-MM-DD.txt` read-only (444). If a file already exists for that date, it's kept.
  4. Points `state/packages-baseline.txt` (a symlink) at the newest baseline.
  5. Keeps the newest **365** dated baselines and deletes only older `packages-YYYY-MM-DD.txt` files.
  6. Holds `.restore-all.lock`.
  Exit codes: 0 saved, no change · 10 saved and differences found (the report path goes on stdout) · 75 busy · 1 failed.
- `install.sh` takes the first baseline if none exists. Without any baseline, `check` fails with "baseline ... missing".

## What the check does
- `check` is read-only. It compares the live package list against the **newest** baseline only.
  - It **alerts** on MISSING packages (in the baseline, not installed) and EXTRA packages (installed, not in the baseline).
  - VERSION CHANGES are informational: they're shown, but they never alert on their own.
  - Each difference is reported once. If the missing/extra set (plus the baseline name) hashes to the same value as the last report
    (`state/drift/last-reported`), the check passes with "drift unchanged since <date>, already reported". New or changed drift
    alerts again, and so does drift against a newer baseline.
- `restore` **installs and removes nothing** and never writes a baseline. It writes `state/drift/drift-YYYY-MM-DD-HHMMSS.txt`,
  records the hash, and exits 2 (NEEDS HUMAN), so `restore-all.sh` exits 20.
- An alerted drift that's still present at the next daily snapshot is absorbed into that day's baseline, and it's also recorded in that
  day's overnight report.
- To accept the current package set right away (owner's explicit request only):
  `/workspace/bin/restore-baseline-accept.sh --reason "why" --by WHO`.

## When asked to look at an alert
1. Read the newest report: `ls -t /workspace/restore/state/drift/*.txt | head -1`.
2. Summarize MISSING/EXTRA for the owner. Don't install, remove, or "fix" packages unless they ask for that specific change.
3. Never edit, delete, or hand-write files in `state/baselines/`. Only the daily snapshot script writes them.

## Test hooks (for testing only)
- `PKG_DRIFT_STATE=<temp state root>` and `PKG_DRIFT_CURRENT=<file of name<TAB>version>` for the check/restore.
  `PKG_DRIFT_BASELINE` and `PKG_DRIFT_DIR` override single paths.
- `restore-baseline-snapshot.sh --state-dir <temp> --date YYYY-MM-DD [--keep N]`.

## Hard rules
No package installs or removals, no baseline edits, no secrets in output. Don't touch Docker port 2375 or /opt.
