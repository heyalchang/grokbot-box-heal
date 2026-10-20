# 10-tailscale: instructions for the agent fallback

This is item `10-tailscale` of the general restore runner (`/workspace/bin/restore-all.sh`, see /workspace/restore/README.md).
The item check is `/workspace/restore/items/10-tailscale/check` (exit 0 = healthy). The item restore wraps the script below.
(Paths assume the default workspace `/workspace`; if `BOX_WORKSPACE` is set, use that instead.)

The expected values live in `/workspace/restore/config.env` (read it; it holds no secrets):
`WANT_HOST` (node hostname), `WANT_TAILNET` (tailnet / login name), optional `WANT_SUFFIX` (MagicDNS suffix) and
optional `WANT_IP` (expected Tailscale IP; informational only).

Your job is to get Tailscale on this box back to this state:
**Running, node `$WANT_HOST`, tailnet `$WANT_TAILNET`, Tailscale SSH on** (and IP `$WANT_IP` if set).
Use the saved node state. Never do a fresh login. Never approve anything.

## Step 1: run the script (always do this first)
```bash
TS_RESTORE_CALLER=agent /workspace/bin/tailscale-restore.sh; echo "exit=$?"
tail -n 20 /workspace/tailscale/restore.log
```
Exit codes:
- `0`: healthy or restored. Run the Verify step, report, and stop.
- `2`: **NEEDS LOGIN** (or config.env not filled in). Stop here. Do not run `tailscale login`, and do not run `tailscale up`
  in a way that opens or prints a login URL. Do not create auth keys. Log it (see Logging) and report that the box owner has to
  sign in themselves.
- `75`: another restore holds the lock. Wait 30 s and run the script once more.
- `3`: no passwordless sudo. `4`: binaries unavailable. `5`: tailscaled won't start. `6`: still unhealthy. For any of these, go to Step 2.

## Step 2: troubleshoot (only if the script failed with 3/4/5/6)
Check each item, fix what you find, then **re-run the script**. The script stays the tool that does the real work.
1. **Binaries.** `ls -la /usr/local/bin/tailscale /usr/local/bin/tailscaled /workspace/tailscale/bin/`.
   Reinstall offline from the backup:
   `sudo install -m 0755 /workspace/tailscale/bin/tailscale /workspace/tailscale/bin/tailscaled /usr/local/bin/`.
   Download only if the backup is missing. The script itself does that: it fetches the official static tarball from
   pkgs.tailscale.com, verifies its sha256, and saves the binaries into /workspace/tailscale/bin.
2. **Dirs/devices.** `sudo mkdir -p /var/run/tailscale`. `/dev/net/tun` must be a char device 10,200:
   `sudo mkdir -p /dev/net && sudo mknod /dev/net/tun c 10 200 && sudo chmod 0666 /dev/net/tun`.
3. **Saved state.** It must exist and be non-empty: `sudo test -s /workspace/tailscale/state/tailscaled.state && echo present`.
   Do NOT open, cat, copy, or print it. If it is missing, the script restores it itself from the box-owned backup
   `/workspace/tailscale/state-backup/` (see below). If there is no usable backup, that means NEEDS LOGIN, so stop and report.
4. **Daemon.** `pgrep -ax tailscaled`. Start it exactly like this (kernel tun mode, root):
   ```bash
   sudo mkdir -p /workspace/tailscale/logs
   sudo sh -c 'cd / && nohup setsid /usr/local/bin/tailscaled \
     --state=/workspace/tailscale/state/tailscaled.state \
     --statedir=/workspace/tailscale/state \
     --socket=/var/run/tailscale/tailscaled.sock \
     >>/workspace/tailscale/logs/tailscaled-$(date +%F).log 2>&1 </dev/null &'
   ```
   If it dies, read the **end** of that daemon log (`tail -n 60`). It holds no secrets, but don't paste anything that looks like a key.
5. **Profile.** `sudo tailscale switch --list`. The active profile (marked `*`) must be `$WANT_TAILNET`.
   If it isn't: `sudo tailscale switch <ID of the $WANT_TAILNET row>`. Never remove any profile.
6. **Bring up.** Only if BackendState is `Stopped` (not `NeedsLogin`):
   `sudo timeout 45 tailscale up --ssh --hostname=$WANT_HOST --accept-dns=false --accept-routes=false --timeout=30s`.
   If the output mentions a login URL or "To authenticate", that is NEEDS LOGIN: stop and report, and don't relay the URL anywhere.
   If it's Running but SSH is off: `sudo tailscale set --ssh`.

## State backup (`/workspace/tailscale/state-backup/`)
The real state dir is root-only (0700), so a computer update can drop it while box-owned files survive.
The script keeps a box-owned copy: dir 0700, files 0600, owned by the box user: `tailscaled.state`, `ssh/` host keys, `certs/`, plus `.meta`
(`source=Running tailnet=... saved=...`, no secrets).
- **Refresh:** only at the end of a run that verified `Running` on `$WANT_TAILNET`, and only if checksums differ (copied to a tmp dir, verified, then mv'd in).
- **Restore:** only if `tailscaled.state` is missing/empty **and** tailscaled is not running. Logged as `ACTION: restored tailscaled state from state-backup`.
- **Logged-out live node + differing backup:** the script only logs a `WARN` and exits 2. It never overwrites a live state file.
  Only the box owner decides whether to stop tailscaled and move the live state aside so the backup gets restored.
- Treat the backup exactly like the state dir: never cat, print, copy elsewhere, or upload it.

## Verify
```bash
tailscale status --json | jq -c '{BackendState, tailnet:.CurrentTailnet.Name, host:.Self.HostName, ip:.Self.TailscaleIPs[0], online:.Self.Online}'
tailscale debug prefs | jq -c '{RunSSH, Hostname}'
```
Expected: `Running`, `$WANT_TAILNET`, `$WANT_HOST`, (`$WANT_IP` if set), `RunSSH: true`.
Then `/workspace/restore/items/10-tailscale/check` must exit 0.

## Logging
Append one timestamped line per action you take, and one final result line, to `/workspace/tailscale/restore.log`
(the Tailscale script's own log) **and** `/workspace/restore/restore.log` (the runner's log), e.g.
`echo "$(date '+%F %T %Z') [agent] <what you did / result>" >> /workspace/tailscale/restore.log`.
If you hit a login wall, the final line must contain `NEEDS LOGIN` (the runner treats that as NEEDS HUMAN).

## Hard rules
- Never print, cat, copy, upload, or log keys, auth tokens, login URLs, or the contents of `/workspace/tailscale/state/*` or `/workspace/tailscale/state-backup/*`, `~/.grok/auth.json`, or any credential file.
- Never run `tailscale login`, never do a fresh `tailscale up` that needs approval, never mint auth keys, never touch the Tailscale admin API or ACL/policy.
- Never `tailscale logout` and never remove a profile.
- Don't touch Docker port 2375. Don't edit platform files under /opt or /usr/local/bin other than the two tailscale binaries.
- Keep it short. When it's restored or NEEDS LOGIN, finish with a one-paragraph summary: what was wrong, what you did, and the final Verify output.
