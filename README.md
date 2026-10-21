# grokbot-box-heal

A small self-heal kit for a Grok Bot box (the shared Linux VM your Grok Bot agents run on).

A platform "Update Bot's Computer" can move the box to a fresh instance. Box-owned files under `/workspace` survive; `/usr/local/bin`,
apt packages, running daemons, and root-only files (even under `/workspace`) do not. There is no cron and no systemd (PID 1 is
`tini`), so nothing runs on a fresh instance until some shell starts. This kit notices that and puts things back, with plain scripts:

- **050-hostname** (optional): keeps the Linux hostname at `WANT_OS_HOSTNAME` after a computer update (`/etc/hosts`, `hostname`,
  `/etc/hostname`) and repoints Chrome profile locks written under the old name. Empty setting = off.
- **100-tailscale**: reinstalls the Tailscale binaries from the offline copy in `/workspace/tailscale/bin/`, recreates
  `/dev/net/tun` and the socket dir, restores the root-only node state from a box-owned backup, starts `tailscaled`, switches to the
  right profile, and makes sure the hostname is set and Tailscale SSH matches `TAILSCALE_SSH`. **It never logs in and never downloads binaries.** No usable state or missing binaries means NEEDS HUMAN.
- **150-tailscale-online**: fails when the node is `Running` but `Self.Online=false` (a dead control session, which item 100 can't
  see) and unsticks it by aborting tailscaled's stuck TCP sockets with `ss -K`. The box VM is paused while idle and a host-side
  proxy drops those flows silently; without this the node is off the tailnet for ~15 min after every pause. It also runs the
  **watchdog**, a 60 s loop that does the same between runner runs and calls `tailscale-restore.sh` if `tailscaled` dies while idle (one copy, capped, `DISABLED` file to stop it).
- **200-package-drift** (alert-only): compares the dpkg package list against the newest daily baseline and reports packages that went MISSING or
  appeared EXTRA. It never installs or removes anything.
- **250-gh-auth** (optional): keeps the GitHub CLI login in `/workspace/config/gh` (so it survives an update), re-links
  `~/.config/gh` to it and re-runs `gh auth setup-git`. **It never logs in.**
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

Until `WANT_HOST` and `WANT_TAILNET` are set, `100-tailscale` reports NEEDS HUMAN. If you don't use Tailscale, disable both Tailscale items:
`touch /workspace/restore/items/{100-tailscale,150-tailscale-online}/DISABLED` (item 150 would otherwise start its watchdog loop).

## Install
Requirements: bash 5, `jq`, `flock`, `timeout`, `setsid`, `ss` (iproute2), and passwordless `sudo -n`.
```bash
git clone https://github.com/heyalchang/grokbot-box-heal.git /workspace/src/grokbot-box-heal   # OWNER = this repo's owner
cd /workspace/src/grokbot-box-heal && ./install.sh
$EDITOR /workspace/restore/config.env
```
Keep the clone where it is (`install.sh` records its path in `state/kit-source` for item 300). `install.sh` is idempotent and
non-interactive; re-running it after a `git pull` is how you update. It copies scripts, items, and jobs, creates `config.env` only if
missing (an existing one is never overwritten; settings new in a version are appended with their defaults, marked "added by update"),
records the installed version and commit,
installs or replaces the 3-line `~/.bashrc` block between `# >>> box auto-restore >>>` and `# <<< box auto-restore <<<` (leaving the rest of
the file alone; a backup goes to `state/`), and takes the first package baseline if none exists. It never runs a login.
Options: `--no-hook`, `--no-baseline`, `--hook-only`. To try it in a scratch dir: `WORKSPACE=/tmp/x BASHRC=/tmp/x/bashrc ./install.sh`
(scripts then need `BOX_WORKSPACE=/tmp/x`).

Re-installing re-copies kit files but never deletes your own items, jobs, or `DISABLED` flags.
To uninstall the hook, delete the lines between (and including) the two markers.

## One-time human steps
These need a person. Agents must never do them, and must never relay a login link or code.

**Offline Tailscale binaries** (`/workspace/tailscale/bin/`; the kit never downloads binaries on the box):
On your own machine, download the official static tarball from `https://pkgs.tailscale.com/stable/` for the box's architecture,
verify its `.sha256` checksum, and `scp` `tailscale` and `tailscaled` into `/workspace/tailscale/bin/` (`chmod 0755`).

**Tailscale sign-in** (once per node; afterwards the state backup carries it across updates):
```bash
. /workspace/restore/config.env
/workspace/bin/tailscale-restore.sh --first-run; echo "exit=$?"   # installs binaries, starts tailscaled with an empty state; exits 2
sudo tailscale up --ssh --hostname="$WANT_HOST" --accept-dns=false --accept-routes=false   # --ssh only if TAILSCALE_SSH=on (the default); drop it if off
#   -> open the sign-in link it prints in YOUR browser and approve the node
/workspace/bin/tailscale-restore.sh; echo "exit=$?"               # expect 0; this also writes the first state backup
/workspace/restore/items/100-tailscale/check
```
If Tailscale already runs on the box with its state somewhere else, stop it and move its state into `/workspace/tailscale/state/`
(root-owned, 0700) first, or just sign in fresh as above. Consider disabling key expiry for this node in the Tailscale admin console,
otherwise the node needs a new sign-in when its key expires.

**gh device login (optional)**, stored where it survives an update:
```bash
mkdir -p /workspace/config/gh && chmod 700 /workspace/config/gh
[ -d ~/.config/gh ] && [ ! -L ~/.config/gh ] && cp -a ~/.config/gh/. /workspace/config/gh/ && mv ~/.config/gh ~/.config/gh.old
mkdir -p ~/.config && ln -sfn /workspace/config/gh ~/.config/gh
gh auth login --hostname github.com --git-protocol https --web --insecure-storage   # approve the one-time code in your browser
gh auth setup-git
chmod 600 /workspace/config/gh/*
```
`--insecure-storage` is needed because the box has no keyring; the token goes into `hosts.yml`. Set `GH_USER` in config.env if you
want the check to insist on a specific account.

## Security trade-off (read this)
To survive an update, two secrets live as plain files readable by the box user:
- `/workspace/tailscale/state-backup/` holds a copy of the Tailscale node state (node key, SSH host keys, certs). Anyone who can read
  it can impersonate this node on your tailnet.
- `/workspace/config/gh/hosts.yml` holds the gh OAuth token with the scopes you granted.

The box is one machine shared by **all** of your Grok Bot agents, so every agent can read these files. Files are 0600/0700, which
only stops other Unix users. If that's not acceptable, skip the gh step, disable `250-gh-auth`, and/or limit what the node and token can
reach (Tailscale ACLs/tags, a fine-grained or narrowly scoped GitHub token). The scripts never print, log, or upload these
contents, and every `INSTRUCTIONS.md` forbids agents from doing so.

## How the runner works
`/workspace/bin/restore-all.sh [--caller NAME] [--only SUBSTR] [--quiet]`

1. **Heal items** (`items/NNN-name/` in order, under `.restore-all.lock`; `_template` is skipped):
   - Run `check` (60 s limit). Exit 0 = healthy, move on.
   - Otherwise run `restore` (600 s limit, stdin `/dev/null`), then `check` again.
2. **Periodic jobs** (`jobs/NNN-name/` in order, after releasing `.restore-all.lock` and taking `.restore-jobs.lock`; `_template` is skipped):
   - Each job has an `INTERVAL` file (whole seconds `>= 60`, e.g. `86400` for daily) and an executable `run` script.
   - Checked against `state/job-last-run.<name>`. If not due yet (and `--only` was not given), skipped silently with no log line (if the previous run failed, its `NEEDS HUMAN` / `FAILED` status is still surfaced until the next run succeeds).
   - When due (or matched by `--only`), run `run` (600 s limit, stdin `/dev/null`).
3. One summary line per item (and per due/failing job) goes to stdout and `restore.log`. One item or job failing never stops the others.

### Exit codes (worst wins: 30 > 20 > 10 > 0)
| code | meaning | alert? |
|---|---|---|
| 0  | everything healthy, nothing done (or only routine jobs ran with exit 0) | no |
| 10 | something was restored, or a job did work (exit 10); all fine now | FYI |
| 20 | NEEDS HUMAN: an item or job needs a person (Tailscale NEEDS LOGIN, package drift, gh token rejected, config missing) | **yes** |
| 30 | FAILED: an item is still broken after restore, or a job failed | **yes** |
| 75 | another runner holds the lock; nothing done | no |

**Shared exit-code table for everything the runner calls** (`restore`, `run`, `tailscale-restore.sh`, `restore-baseline-snapshot.sh`):
`0` ok · `2` needs a human · `10` did work (jobs only; for items the runner sees work by checking before and after) · `75` busy, skip this round · anything else = failed. (`check` exits `0` when healthy, nonzero when it needs `restore`.)

## The `~/.bashrc` hook
The `~/.bashrc` block is three lines (`[ -r /workspace/bin/restore-hook.sh ] && . /workspace/bin/restore-hook.sh` between markers)
above the interactive guard, so `bash -ilc` (agents), SSH and login shells all source it without forking. Silent, scripts only:
- **Rate limit:** stamp `state/hook-last-run` holds "<boot id> <epoch>". Younger than 15 min and same boot: nothing else happens (no fork, ~0.05 ms on bash 5, where `$EPOCHSECONDS` exists; otherwise one `date +%s`). A missing or unusable epoch (non-numeric, oversized, or in the future) is stale: one launch, never an error and never a skip. If the boot id cannot be read, the stamp uses `-` so the 15-minute limit still applies. If `date` fails too, every shell launches and the log shows it.
  Otherwise it rewrites the stamp first (atomically, so concurrent shells skip), then:
- **Launches `restore-all.sh --caller bashrc --quiet`** in the background, detached. On a new boot (boot id differs) and on the same boot alike. The hook does not inspect Tailscale or anything else itself: the items and jobs are the checks. A persistently broken box gets at most one run per 15 min. If `sudo -n` fails, the hook logs that and does not launch.
- **Log:** each hook launch appends one `[hook]` line to `restore/restore.log` (which the runner rotates at 1 MB to `restore.log.1` under its lock). Fast-path skips are never logged. A failed write does not break the shell.
- Loop guard: `RESTORE_ACTIVE` (set by the runner and watchdog) disables the hook in shells they spawn.
- **What it costs:** one restore-all run per 15 minutes of agent activity: a few hundred ms of CPU, one `gh api user` call
  (item 250), one dpkg query (item 200), six lines in `restore.log` (plus due jobs). Nothing runs while no shell starts except the Tailscale watchdog (to re-arm the watchdog after its 6-actions/hour cap, remove `state/ts-watchdog.capped`); the daily routine is the backstop.
- Item **300-bashrc-hook** checks that `bin/restore-hook.sh` and the 3-line block are still there and puts them back with `install.sh --hook-only` if an update reset the file.

## Updates
Read `git -C <clone> fetch origin main && git -C <clone> log --oneline <installed>..origin/main` first; the box runs this as root.
```bash
git -C <clone> pull --ff-only && <clone>/install.sh && /workspace/bin/restore-all.sh --caller manual; echo exit=$?
```
To roll back: check out the previous commit in the clone and re-run `install.sh`. What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## Suggested daily Grok Bot routine
The hook only fires when some shell starts, so add one Grok Bot routine, once a day, as the backstop and alert path. Example prompt:

> Daily box health check. Run `/workspace/bin/restore-all.sh --caller routine; echo "exit=$?"`. Then read the last 24 h of
> `/workspace/restore/restore.log`. If the exit was 0, 10 or 75 and the log shows nothing new and alarming, stay silent. If it was
> 20 or 30, message me with one short paragraph: which item or job, what the summary line says, and what I need to do (for package
> drift, summarize the newest report in `/workspace/restore/state/drift/`). Never print secrets, never sign in to anything, never
> relay a login link or code, never install or remove packages unless I ask.

## Adding an item or periodic job
**Heal item** (`/workspace/restore/items/NNN-name/`, checked every 15 min; 050..300 are used by the kit, spaced by 50):
1. `cp -r /workspace/restore/items/_template /workspace/restore/items/350-myname`
2. `check`: read-only, fast (60 s hard limit), exit 0 if healthy (nonzero if it needs `restore`), print one short line saying what it saw.
3. `restore`: idempotent, non-interactive (stdin is `/dev/null`, 600 s limit), `sudo -n` for root, prefer offline copies kept under
   `/workspace` over the network, using the shared exit-code table above (`0` / `2` / `75` / other = failed).
4. `INSTRUCTIONS.md`: runbook for a person or the daily agent (what healthy means, the steps, when to stop, and the hard rules).
5. `chmod +x check restore`, then test: `/workspace/bin/restore-all.sh --only 350-myname`.
6. `touch DISABLED` to pause an item.

**Periodic job** (`/workspace/restore/jobs/NNN-name/`, runs at most once per `INTERVAL` seconds; 400 is used by the kit):
1. `cp -r /workspace/restore/jobs/_template /workspace/restore/jobs/450-myjob`
2. Put the minimum seconds between runs (`>= 60`, e.g. `86400` for daily) in `INTERVAL`.
3. `run`: executable script (600 s limit, stdin `/dev/null`) that does the job, prints one short line, and exits per the shared exit-code table above (`0` / `2` / `10` / `75` / other = failed).
4. `chmod +x run`, then test now (ignores `INTERVAL` when `--only` is set): `/workspace/bin/restore-all.sh --only 450-myjob`.
5. `touch DISABLED` to pause a job.

Env given to `check`/`restore`/`run`: `ITEM_NAME`/`JOB_NAME`, `ITEM_DIR`/`JOB_DIR`, `RESTORE_CALLER`, `RESTORE_LOG`, `RESTORE_CONFIG`, `BOX_WORKSPACE`,
`RESTORE_ACTIVE=1`. Read your own settings from `$RESTORE_CONFIG`. Items and jobs you add are never touched by `install.sh`
unless they share a name with a kit one.

## Platform quirks, the Restore bot, and design invariants (read before changing the kit)

### How this kit and the Restore Grok Bot fit together
- **Tools vs. agent:** This repo is **only the local shell toolkit** installed on the VM. Separately, a Grok Bot agent (**Restore**) runs the daily health routine and helps the owner inspect drift/alerts or review and apply kit updates when asked.
- **One-way boundary (by design):** The VM **never** webhooks back into Grok Bot land, **never** spawns headless LLM agents from inside the runner, and **never** self-updates or downloads binaries on its own. Scripts check, restore from local `/workspace` copies, and write to `restore/restore.log`; the Restore bot (or the owner) reads the log and decides what to do next.

### 1. Platform quirks (why this kit exists)
- **What a "Computer Update" wipes vs. keeps:** User-owned files under `/workspace` survive. Everything outside `/workspace` (`/usr/local/bin`, `/etc`, apt packages), all running daemons, and **root-only files even inside `/workspace`** (such as `/workspace/tailscale/state/`) do not survive. `~/.bashrc` may also be reset.
- **No init, no cron:** PID 1 is `tini`. Nothing starts on a fresh instance until some shell opens.
- **Idle VM pause + silent TCP drop:** The platform pauses the VM while idle. Outbound TCP goes through a host-side transparent proxy that silently drops idle flows across a pause without sending an RST. On resume, `tailscaled` sits on dead sockets for ~15 min (`tcp_retries2=15`) while `BackendState` still reports `Running` and `Self.Online` lags by minutes. Aborting stuck `tailscaled` sockets (`ss -K`) forces an immediate redial without restarting the daemon.
- **Shared trust boundary:** One Linux user (`box`) with passwordless `sudo -n` is shared by every bot on the VM.

### 2. Hard invariants (do not "improve" these away)
- **Hook while active, daily routine as backstop — no background cron daemon:** `restore-all.sh` is triggered **only** by `bin/restore-hook.sh` when a shell starts (at most once per 15 min) and by the once-a-day Grok Bot routine. Do **not** make the Tailscale watchdog call `restore-all.sh`: that turns the watchdog into an unattended 24/7 cron daemon, hits GitHub (`250-gh-auth`) 96 times a day with nobody watching, and couples the watchdog to the runner lock.
- **The Tailscale watchdog does one job:** Every `WATCHDOG_INTERVAL` seconds, abort stuck TCP sockets after a VM pause, or run `timeout 300 tailscale-restore.sh` if `tailscaled` has been down/non-`Running` for 2+ ticks.
  - **Socket aborts on a `Running` node that recover (`rc=0`) do not count toward the 6/hour cap** — pausing every 15 min is normal life on this VM.
  - **Failed actions (`rc != 0`) and daemon restarts (`why` contains `state=`) do count** in `state/ts-watchdog.fails`, so a crash-looping `tailscaled` stops after 6 in an hour, writes `state/ts-watchdog.capped` (removing `ts-watchdog.fails`), and raises `NEEDS HUMAN`.
  - **`NeedsLogin`, `NeedsMachineAuth`, and `Stopped` are hands-off:** Never trigger or count socket aborts or restarts in those states (a human ran `tailscale down` or has not signed in).
- **Heal items (`items/`) vs. periodic jobs (`jobs/`):**
  - `items/NNN-name` (`check` → `restore` → `check`, under `.restore-all.lock`) are fast state assertions checked every 15 min while active.
  - `jobs/NNN-name` (`INTERVAL` + `run`, under `.restore-jobs.lock` **after** `.restore-all.lock` is released) are periodic tasks (like the 24 h dpkg baseline). Releasing `.restore-all.lock` before the job pass lets a job call a script that takes `.restore-all.lock` without passing lock-bypass env vars across processes.
- **Detached children must never inherit locks or loop-guard env vars:** When `restore` launches `watchdog` or the hook launches `restore-all.sh`, close extra fds (`3..9`) and explicitly set or clear `RESTORE_ACTIVE`. Never use an inherited env var to bypass `flock`.
- **No unattended self-update, no binary downloads, no headless agent fallback, no interactive logins, no secrets in output:**
  - The kit runs as root next to Tailscale; updates are reviewed first and run deliberately (`git pull && ./install.sh`), never via an unattended job.
  - Tailscale binaries come only from the offline copy in `/workspace/tailscale/bin/`.
  - Never print, log, or copy keys, tokens, passwords, login links, or state/credential contents. No fresh logins and no minting credentials. Keep durable copies in `/workspace`.
- **One journal (`restore/restore.log`) and two exit-code tables:**
  - All kit actions log to `/workspace/restore/restore.log` with a bracketed component tag (rotated at 1 MB by the runner under its lock). `tailscale/logs/ts-watch.log` is the per-tick trace.
  - Runner (`restore-all.sh`) exits: `0` ok · `10` restored/did work · `20` NEEDS HUMAN · `30` FAILED · `75` busy.
  - Everything the runner calls shares one table: `0` ok · `2` needs human · `10` did work (jobs only) · `75` busy (skip without stamping) · anything else = failed.

## License
MIT, see [LICENSE](LICENSE).
