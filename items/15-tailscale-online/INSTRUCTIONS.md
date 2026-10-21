# 15-tailscale-online
Healthy = `sudo tailscale status --json` shows `BackendState=Running` and `Self.Online=true`, and the `watchdog` loop is running
(or `DISABLED` is present). Item 10 only checks `Running`, which stays true while the control session is dead.
Why: the box VM is paused while idle. All outbound TCP goes through a host-side proxy that drops tailscaled's flows across a pause
without an RST, so tailscaled retransmits into dead sockets for ~15 min and the node drops off the tailnet. `restore` aborts those
sockets with `ss -K` (exact 4-tuple, tailscaled's only); tailscaled redials and is online again in about a second. Same node, no
login, no restart.
`watchdog` is a 60 s loop (`WATCHDOG_INTERVAL` in config.env, required, 30..600) that does the same between runner runs: one copy
via flock on `state/ts-watchdog.lock`, one action per 60 s at most, and after `MAX_ACTIONS` (6) *failed* actions in a rolling hour
it stops acting, writes `state/ts-watchdog.capped`, and this check fails as NEEDS HUMAN. Log: `$BOX_WORKSPACE/tailscale/logs/ts-watch.log`
(one line per tick, rotated at 5 MB). `restore` (run by restore-all) starts the watchdog when it is not running and `DISABLED` is absent.
Stop it: `pkill -f items/15-tailscale-online/watchdog`. Keep it off: `touch DISABLED` here (the loop exits within one tick).
Re-arm after the cap: read the log, then `rm state/ts-watchdog.capped` and run restore-all.
NO_AGENT is set: failures alert the owner. Hard rules: never run `tailscale up`/login, never print keys, state contents, or login URLs.
