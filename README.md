# grokbot-box-heal

A small self-heal kit for a Grok Bot box: the shared Linux VM your Grok Bot agents run on.  Platform resets, spontaneous re-installs and machine sleeps can reset state and hang tailscale.   This puts the box back together after the platform resets and keeps Tailscale reachable through the VM's idle pauses.

Note to agents:  "boundary and the invariants" section is at the end.

## The Grokbot VM box

What the kit is built around. Confirmed on a live box unless marked otherwise.

- No init system: PID 1 is `tini`. No cron, no systemd. Nothing runs on a fresh instance until some shell starts.
- A platform "Update Bot's Computer" moves the box to a fresh instance. Box-owned files under `/workspace` survive; `/usr/local/bin`, apt packages, running daemons and `~/.bashrc` are reset. The kit also assumes root-owned files under `/workspace` (the Tailscale state dir) are lost.
- The VM is paused while idle, often. Outbound TCP goes through a host-side proxy that drops flows across a pause without an RST, so on resume `tailscaled` sits on dead sockets for about 15 minutes (`tcp_retries2=15`) while still reporting `Running`. Aborting the stuck sockets (`ss -K`) makes it redial at once.
- One Linux user, `box`, with passwordless `sudo -n`, shared by every agent on the VM. There is no finer trust boundary inside the box.

## What it does

- **050-hostname** (optional): keeps the Linux hostname at `WANT_OS_HOSTNAME` after a computer update (`/etc/hosts`, `hostname`, `/etc/hostname`) and repoints Chrome profile locks written under the old name. Empty setting = off.
- **100-tailscale**: reinstalls the Tailscale binaries from the offline copy in `/workspace/tailscale/bin/`, recreates `/dev/net/tun` and the socket dir, restores the root-only node state from a box-owned backup, starts `tailscaled`, switches to the right profile, and makes sure the hostname is set and Tailscale SSH matches `TAILSCALE_SSH`. **It never logs in and never downloads binaries.** No usable state or missing binaries means NEEDS HUMAN.
- **150-tailscale-online**: fails when the node is `Running` but `Self.Online=false` (a dead control session, which item 100 can't see) and unsticks it by aborting tailscaled's stuck TCP sockets with `ss -K`. The box VM is paused while idle and a host-side proxy drops those flows silently; without this the node is off the tailnet for ~15 min after every pause. It also runs the **watchdog**, a 60 s loop that does the same between runner runs and calls `tailscale-restore.sh` if `tailscaled` dies while idle (one copy, capped, `DISABLED` file to stop it).
- **200-package-drift** (alert-only): compares the dpkg package list against the newest daily baseline and reports packages that went MISSING or appeared EXTRA. It never installs or removes anything.
- **250-gh-auth** (optional): keeps the GitHub CLI login in `/workspace/config/gh` (so it survives an update), re-links `~/.config/gh` to it and re-runs `gh auth setup-git`. **It never logs in.**
- **300-bashrc-hook**: puts the 3-line `~/.bashrc` hook block back if a computer update reset the file (`install.sh --hook-only`).
- **jobs/400-baseline-snapshot** (periodic job, 24 h): saves the daily dpkg package baseline (`restore-baseline-snapshot.sh`).
- A **runner** (`restore-all.sh`) walks `items/NNN-name/` in order (`check` -> `restore` -> `check`), then walks `jobs/NNN-name/` (`INTERVAL` + `run`) for periodic jobs that are due.
- A **`~/.bashrc` hook** (`bin/restore-hook.sh`, sourced by a 3-line block in `~/.bashrc`) that launches the runner from any shell (agent, SSH, login) at most once per 15 minutes, with no fork in between. The runner is the box's only scheduler: while agents are working, every item (and any due job) is checked every 15 minutes.

## Layout after install
```
/workspace/bin/restore-all.sh                  runner (heal items + periodic jobs)
/workspace/bin/restore-hook.sh                 sourced by the 3-line ~/.bashrc block
/workspace/bin/tailscale-restore.sh            Tailscale restore (usable on its own)
/workspace/bin/restore-baseline-snapshot.sh    daily package baseline (run by job 400-baseline-snapshot)
/workspace/bin/restore-baseline-accept.sh      accept the current package set now (owner's explicit request only)
/workspace/restore/
  config.env                                   your settings (not in git; created from config.env.example)
  README.md                                    this file
  restore.log                                  kit journal: runner, hook, tailscale-restore, item 150, watchdog cap (rotated at 1 MB to restore.log.1)
  state/                                       locks, hook/job stamps, baselines/, drift/ reports,
                                               kit-version, kit-source, ts-watchdog.fails, ts-watchdog.capped
  items/_template, 050-hostname, 100-tailscale, 150-tailscale-online, 200-package-drift, 250-gh-auth, 300-bashrc-hook
  jobs/_template, 400-baseline-snapshot
/workspace/tailscale/                          bin/ (offline binaries), state/ (root-only), state-backup/,
                                               logs/ (tailscaled-<date>.log, pruned >14d on start; ts-watch.log: one line per watchdog tick)
/workspace/config/gh/                          persistent gh login (optional)
```

## Configuration
Everything personal comes from one file, `/workspace/restore/config.env` (sourced by bash; holds no secrets):

| key | required | meaning |
|---|---|---|
| `WANT_HOST` | yes (100-tailscale) | Tailscale hostname this node should have |
| `WANT_TAILNET` | yes (100-tailscale) | tailnet name, i.e. `tailscale status --json \| jq -r .CurrentTailnet.Name` (usually your login name for a personal tailnet) |
| `WANT_SUFFIX` | no | MagicDNS suffix (`*.ts.net`); empty = not checked |
| `WANT_IP` | no | expected Tailscale IP; empty = not checked. A mismatch is only reported, never treated as broken |
| `TAILSCALE_SSH` | no | `on` (default) or `off`: whether other devices on your tailnet can SSH into this box via Tailscale SSH |
| `GH_USER` | no | GitHub login gh should be signed in as; empty = any account (and the item passes if gh auth isn't set up) |
| `WANT_OS_HOSTNAME` | no | Linux hostname item 050 keeps; empty = not managed |
| `WATCHDOG_INTERVAL` | yes (150-tailscale-online) | watchdog tick in seconds, 30..600 (60 in the example). Missing or malformed: the watchdog refuses to start and item 150 fails |

Until `WANT_HOST` and `WANT_TAILNET` are set, `100-tailscale` reports NEEDS HUMAN. If you don't use Tailscale, disable both Tailscale items: `touch /workspace/restore/items/{100-tailscale,150-tailscale-online}/DISABLED` (item 150 would otherwise start its watchdog loop).

## Install
Requirements: bash 5, `jq`, `flock`, `timeout`, `setsid`, `ss` (iproute2), and passwordless `sudo -n`.
```bash
git clone https://github.com/heyalchang/grokbot-box-heal.git /workspace/src/grokbot-box-heal   # OWNER = this repo's owner
cd /workspace/src/grokbot-box-heal && ./install.sh
$EDITOR /workspace/restore/config.env
```
Keep the clone where it is (`install.sh` records its path in `state/kit-source` for item 300). `install.sh` is idempotent and non-interactive; re-running it after a `git pull` is how you update. It copies scripts, items, and jobs, creates `config.env` only if missing (an existing one is never overwritten; settings new in a version are appended with their defaults, marked "added by update"), records the installed version and commit, installs or replaces the 3-line `~/.bashrc` block between `# >>> box
auto-restore >>>` and `# <<< box auto-restore <<<` (leaving the rest of the file alone; a backup goes to `state/`), and takes the first package baseline if none exists. It never runs a login. Options: `--no-hook`, `--no-baseline`, `--hook-only`. To try it in a scratch dir: `WORKSPACE=/tmp/x BASHRC=/tmp/x/bashrc ./install.sh` (scripts then need `BOX_WORKSPACE=/tmp/x`).

Re-installing re-copies kit files but never deletes your own items, jobs, or `DISABLED` flags. To uninstall the hook, delete the lines between (and including) the two markers.

## One-time steps
Once per box. An agent working under the owner's direction can do all of this and hand the owner the sign-in link or one-time code to approve in a browser; that is usually the safer path. The unattended rules still hold: the daily routine and the items never log in, never mint credentials, and never print or relay a link or code on their own.

**Offline Tailscale binaries** (`/workspace/tailscale/bin/`; the kit never downloads them on its own): `install.sh` seeds them automatically by copying a working `tailscale` and `tailscaled` that are already installed (`/usr/local/bin` or on `PATH`). Only if Tailscale isn't installed yet: download the official static tarball from `https://pkgs.tailscale.com/stable/` for the box's architecture, verify its `.sha256` checksum, and put `tailscale` and `tailscaled` into `/workspace/tailscale/bin/` (`chmod 0755`).

**Tailscale sign-in** (once per node; afterwards the state backup carries it across updates):

```bash
. /workspace/restore/config.env
/workspace/bin/tailscale-restore.sh --first-run; echo "exit=$?"   # installs binaries, starts tailscaled with an empty state; exits 2
sudo tailscale up --ssh --hostname="$WANT_HOST" --accept-dns=false --accept-routes=false   # --ssh only if TAILSCALE_SSH=on (the default); drop it if off
#   -> the owner opens the sign-in link it prints in a browser and approves the node
/workspace/bin/tailscale-restore.sh; echo "exit=$?"               # expect 0; this also writes the first state backup
/workspace/restore/items/100-tailscale/check
```
If Tailscale already runs on the box with its state somewhere else, stop it and move its state into `/workspace/tailscale/state/` (root-owned, 0700) first, or just sign in fresh as above. Consider disabling key expiry for this node in the Tailscale admin console, otherwise the node needs a new sign-in when its key expires.

**gh device login (optional)**, stored where it survives an update:
```bash
mkdir -p /workspace/config/gh && chmod 700 /workspace/config/gh
[ -d ~/.config/gh ] && [ ! -L ~/.config/gh ] && cp -a ~/.config/gh/. /workspace/config/gh/ && mv ~/.config/gh ~/.config/gh.old
mkdir -p ~/.config && ln -sfn /workspace/config/gh ~/.config/gh
gh auth login --hostname github.com --git-protocol https --web --insecure-storage   # the owner approves the one-time code in a browser
gh auth setup-git
chmod 600 /workspace/config/gh/*
```
`--insecure-storage` is needed because the box has no keyring; the token goes into `hosts.yml`. Set `GH_USER` in config.env if you
want the check to insist on a specific account.

## Security trade-off (read this)
To survive an update, two secrets live as plain files readable by the box user:
- `/workspace/tailscale/state-backup/` holds a copy of the Tailscale node state (node key, SSH host keys, certs). Anyone who can
  read it can impersonate this node on your tailnet.
- `/workspace/config/gh/hosts.yml` holds the gh OAuth token with the scopes you granted.

The box is one machine shared by **all** of your Grok Bot agents, so every agent can read these files. Files are 0600/0700, which only stops other Unix users. If that's not acceptable, skip the gh step, disable `250-gh-auth`, and/or limit what the node and token can reach (Tailscale ACLs/tags, a fine-grained or narrowly scoped GitHub token). The scripts never print, log, or upload these contents, and every `INSTRUCTIONS.md` forbids agents from doing so.

## How the runner works
`/workspace/bin/restore-all.sh [--caller NAME] [--only SUBSTR] [--quiet]`

1. **Heal items** (`items/NNN-name/` in order, under `.restore-all.lock`; `_template` is skipped):
   - Run `check` (60 s limit). Exit 0 = healthy, move on.
   - Otherwise run `restore` (600 s limit, stdin `/dev/null`), then `check` again.
2. **Periodic jobs** (`jobs/NNN-name/` in order, after releasing `.restore-all.lock` and taking `.restore-jobs.lock`; `_template`
   is skipped):
   - Each job has an `INTERVAL` file (whole seconds `>= 60`, e.g. `86400` for daily) and an executable `run` script.
   - Checked against `state/job-last-run.<name>`. If not due yet (and `--only` was not given), skipped silently with no log line
     (if the previous run failed, its `NEEDS HUMAN` / `FAILED` status is still surfaced until the next run succeeds).
   - When due (or matched by `--only`), run `run` (600 s limit, stdin `/dev/null`).
3. One summary line per item (and per due/failing job) goes to stdout and `restore.log`. One item or job failing never stops the
   others.

### Exit codes (worst wins: 30 > 20 > 10 > 0)
| code | meaning | alert? |
|---|---|---|
| 0  | everything healthy, nothing done (or only routine jobs ran with exit 0) | no |
| 10 | something was restored, or a job did work (exit 10); all fine now | FYI |
| 20 | NEEDS HUMAN: an item or job needs a person (Tailscale NEEDS LOGIN, package drift, gh token rejected, config missing) | **yes** |
| 30 | FAILED: an item is still broken after restore, or a job failed | **yes** |
| 75 | another runner holds the lock; nothing done | no |

**Shared exit-code table for everything the runner calls** (`restore`, `run`, `tailscale-restore.sh`,
`restore-baseline-snapshot.sh`): `0` ok · `2` needs a human · `10` did work (jobs only; for items the runner sees work by checking before and after) · `75` busy, skip this round · anything else = failed. (`check` exits `0` when healthy, nonzero when it needs`restore`.)

## The `~/.bashrc` hook
The block is three lines (`[ -r /workspace/bin/restore-hook.sh ] && . /workspace/bin/restore-hook.sh` between markers), above the interactive guard, so `bash -ilc` (agents), SSH and login shells all source it. Sourcing does not fork.
- At most once per 15 minutes, or at once on a new boot, it launches `restore-all.sh --caller bashrc --quiet` detached. The stamp is `state/hook-last-run` ("<boot id> <epoch>"); an unreadable stamp counts as stale, so a bad stamp can never stop launches or break the shell. If `sudo -n` fails it logs that and does not launch. Details are in the header of `bin/restore-hook.sh`.
- Each launch appends one `[hook]` line to `restore/restore.log`. Fast-path skips are not logged.
- `RESTORE_ACTIVE` (set by the runner and the watchdog) disables the hook in shells they spawn.
- Cost: one runner pass per 15 minutes of agent activity: a few hundred ms of CPU, one `gh api user` call, one dpkg query, a few
  log lines. Nothing runs while no shell starts except the Tailscale watchdog; the daily routine is the backstop.
- Item **300-bashrc-hook** checks the file and the block and puts them back with `install.sh --hook-only`.

## Updates
Read `git -C <clone> fetch origin main && git -C <clone> log --oneline <installed>..origin/main` first; the box runs this as root.
```bash
git -C <clone> pull --ff-only && <clone>/install.sh && /workspace/bin/restore-all.sh --caller manual; echo exit=$?
```
To roll back: check out the previous commit in the clone and re-run `install.sh`. What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## Suggested daily Grok Bot routine
The hook only fires when some shell starts, so add one Grok Bot routine, once a day, as the backstop and alert path. Example
prompt:

> Daily box health check. Run `/workspace/bin/restore-all.sh --caller routine; echo "exit=$?"`. Then read the last 24 h of
> `/workspace/restore/restore.log`. If the exit was 0, 10 or 75 and the log shows nothing new and alarming, stay silent. If it was
> 20 or 30, message me with one short paragraph: which item or job, what the summary line says, and what I need to do (for package
> drift, summarize the newest report in `/workspace/restore/state/drift/`). Never print secrets, never sign in to anything, never
> relay a login link or code, never install or remove packages unless I ask.

## Adding an item or periodic job
**Heal item** (`/workspace/restore/items/NNN-name/`, checked every 15 min; 050..300 are used by the kit, spaced by 50):

1. `cp -r /workspace/restore/items/_template /workspace/restore/items/350-myname`
2. `check`: read-only, fast (60 s hard limit), exit 0 if healthy (nonzero if it needs `restore`), print one short line saying what it saw.
3. `restore`: idempotent, non-interactive (stdin is `/dev/null`, 600 s limit), `sudo -n` for root, prefer offline copies kept under `/workspace` over the network, using the shared exit-code table above (`0` / `2` / `75` / other = failed).
4. `INSTRUCTIONS.md`: runbook for a person or the daily agent (what healthy means, the steps, when to stop, and the hard rules).
5. `chmod +x check restore`, then test: `/workspace/bin/restore-all.sh --only 350-myname`.
6. `touch DISABLED` to pause an item.

**Periodic job** (`/workspace/restore/jobs/NNN-name/`, runs at most once per `INTERVAL` seconds; 400 is used by the kit):

1. `cp -r /workspace/restore/jobs/_template /workspace/restore/jobs/450-myjob`
2. Put the minimum seconds between runs (`>= 60`, e.g. `86400` for daily) in `INTERVAL`.
3. `run`: executable script (600 s limit, stdin `/dev/null`) that does the job, prints one short line, and exits per the shared exit-code table above (`0` / `2` / `10` / `75` / other = failed).
4. `chmod +x run`, then test now (ignores `INTERVAL` when `--only` is set): `/workspace/bin/restore-all.sh --only 450-myjob`.
5. `touch DISABLED` to pause a job.

Env given to `check`/`restore`/`run`: `ITEM_NAME`/`JOB_NAME`, `ITEM_DIR`/`JOB_DIR`, `RESTORE_CALLER`, `RESTORE_LOG`, `RESTORE_CONFIG`, `BOX_WORKSPACE`, `RESTORE_ACTIVE=1`. Read your own settings from `$RESTORE_CONFIG`. Items and jobs you add are never touched by `install.sh` unless they share a name with a kit one.

## For agents: the boundary and the invariants
Read this before changing the kit. Mechanics live in the sections above and in each script's header; this is only what must stay true.

**The boundary.** This repo is the tools on the VM, nothing more. A separate Grok Bot agent (Restore) runs the daily routine, reads `restore/restore.log`, and applies kit updates when the owner asks. The VM never calls back into Grok Bot, never starts a model, never fetches code or binaries, and never updates itself. Scripts check, restore from copies under `/workspace`, and log. People, and agents under direction, do the rest.

**Invariants**, each with the one reason it exists:

1. No daemon but the Tailscale watchdog, and the watchdog never runs the runner. The runner fires only from the hook and the daily routine. A second resident process has the same liveness problem as the first, and a watchdog that schedules is a cron daemon.
2. The watchdog keeps Tailscale reachable and does nothing else. Its cap counts failed actions and daemon restarts, never a socket abort that recovered: pausing is normal life here, and a cap that counted recoveries would disarm itself. In `NeedsLogin`,
   `NeedsMachineAuth` and `Stopped` it does not act at all; a human is already in the loop.
3. Nothing pulls into the box on its own: no self-update, no binary download, no headless agent. Updates are read first, then applied by hand (`git pull && ./install.sh`). The kit runs as root, so a scheduled pull is a root-propagation path.
4. A lock is held by the process that took it. A detached child starts with a clean fd set and no inherited lock or loop-guard state; an env var that bypasses `flock` leaks straight through `setsid`.
5. Secrets never appear in output, logs or copies: node state, tokens, login links, codes. No fresh logins, no minting credentials. Alert-only items never install or remove anything.
6. `/workspace` is the only durable place. Anything that must survive an update lives there as a box-owned file.

## License
MIT, see [LICENSE](LICENSE).
