# 150-tailscale-online: runbook (for a person or the daily agent)

Healthy = `sudo tailscale status --json` shows `BackendState=Running` and `Self.Online=true`, and the `watchdog` loop is running
(or `DISABLED` is present). Item 100 only checks `Running`, which stays true while the control session is dead.
Why: the box VM is paused while idle. All outbound TCP goes through a host-side proxy that drops tailscaled's flows across a pause
without an RST, so tailscaled retransmits into dead sockets for ~15 min and the node drops off the tailnet. `restore` aborts those
sockets with `ss -K` (exact 4-tuple, tailscaled's only); tailscaled redials and is online again in about a second. Same node, no
login, no restart.
`watchdog` is a 60 s loop (`WATCHDOG_INTERVAL` in config.env, required, 30..600) that does the same between runner runs (and calls
`tailscale-restore.sh` if `tailscaled` dies while idle): one copy via flock on `state/ts-watchdog.lock`, one action per 60 s at
most, and after `MAX_ACTIONS` (6) failed actions or daemon restarts in a rolling hour (tracked in `state/ts-watchdog.fails`, one epoch
per line) it stops acting, writes `state/ts-watchdog.capped`, and this check fails as NEEDS HUMAN. Log: `$BOX_WORKSPACE/tailscale/logs/ts-watch.log`
(one line per tick, rotated at 5 MB). `restore` (run by restore-all) starts the watchdog when it is not running and `DISABLED` is absent.
Stop it: `pkill -f items/150-tailscale-online/watchdog`. Keep it off: `touch DISABLED` here (the loop exits within one tick).
To re-arm after the cap: read the log, then remove `state/ts-watchdog.capped` (`ts-watchdog.fails` was already removed when the cap
was reached; no pkill or restart needed).
Failures alert the owner. Hard rules: never run `tailscale up`/login, never print keys, state contents, or login URLs.
