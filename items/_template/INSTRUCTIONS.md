# <Item name>: runbook (for a person or the daily agent)

Read this file when `restore` has failed. Keep it short and concrete.

## Goal
<What "healthy" means, in one or two lines. It should match what `check` tests.>

## Step 1: try the item's own scripts
```bash
ITEM=/workspace/restore/items/NNN-name
$ITEM/check; echo "check=$?"
RESTORE_CALLER=manual $ITEM/restore; echo "restore=$?"
$ITEM/check; echo "check=$?"
```

## Step 2: troubleshoot (only if Step 1 still fails)
<Known causes and their fixes, and the offline sources under /workspace.>

## Stop and report (do not try to work around these)
<e.g. needs an interactive login or approval, needs a paid action, would touch credentials.>
If you hit one, append a line containing `NEEDS HUMAN` to /workspace/restore/restore.log and stop.

## Logging
Append `$(date '+%F %T %Z') [NNN-name] <action/result>` lines to /workspace/restore/restore.log.

## Hard rules (apply to every item)
- Never print, cat, copy, or log keys, tokens, passwords, login URLs, or state/credential file contents.
- No fresh logins, no minting credentials, no admin or policy changes, no deleting anything outside /workspace.
- Don't touch Docker port 2375 or platform files under /opt.
- Finish with a one-paragraph summary: what was wrong, what you did, and the final `check` output.
