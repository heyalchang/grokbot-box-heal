# grokbot-box-heal

A small self-heal kit for a Grok Bot box (the shared Linux VM your Grok Bot agents run on).

A platform "Update Bot's Computer" can move the box to a fresh instance. Box-owned files under `/workspace` survive; `/usr/local/bin`,
apt packages, running daemons, and root-only files (even under `/workspace`) do not. There is no cron and no systemd (PID 1 is
`tini`), so nothing runs on a fresh instance until some shell starts. This kit notices that and puts things back, with plain scripts:

- **10-tailscale**: reinstalls the Tailscale binaries (offline copy first, verified official tarball as fallback), recreates
  `/dev/net/tun` and the socket dir, restores the root-only node state from a box-owned backup, starts `tailscaled`, switches to the
  right profile, and makes sure the hostname and Tailscale SSH are set. **It never logs in.** No usable state means NEEDS LOGIN.
- **20-package-drift** (alert-only): takes a daily snapshot of the dpkg package list and reports packages that went MISSING or
  appeared EXTRA compared to the newest baseline. It never installs or removes anything.
- **30-gh-auth** (optional): keeps the GitHub CLI login in `/workspace/config/gh` (so it survives an update), re-links
  `~/.config/gh` to it and re-runs `gh auth setup-git`. **It never logs in.**
- A **runner** (`restore-all.sh`) walks the items in order: `check`, then `restore`, then `check` again, and (only for items that
  allow it) a rate-limited headless Grok agent fallback that follows the item's `INSTRUCTIONS.md`.
- A **`~/.bashrc` hook** that triggers the runner from any shell (agent, SSH, login), cheaply and rate-limited.

## Layout after install
```
/workspace/bin/restore-all.sh                  runner
/workspace/bin/tailscale-restore.sh            Tailscale restore (usable on its own)
/workspace/bin/restore-baseline-snapshot.sh    daily package baseline
/workspace/bin/restore-baseline-accept.sh      accept the current package set now (owner's explicit request only)
/workspace/restore/
  config.env                                   your settings (not in git; created from config.env.example)
  README.md                                    this file
  restore.log, agent-restore.log               runner log, agent fallback output
  state/                                       lock, boot id, hook stamps, baselines/, drift/ reports
  items/_template, 10-tailscale, 20-package-drift, 30-gh-auth
/workspace/tailscale/                          bin/ (offline binaries), state/ (root-only), state-backup/, logs/, restore.log
/workspace/config/gh/                          persistent gh login (optional)
```

## Configuration
Everything personal comes from one file, `/workspace/restore/config.env` (sourced by bash; holds no secrets):

| key | required | meaning |
|---|---|---|
| `WANT_HOST` | yes (10-tailscale) | Tailscale hostname this node should have |
| `WANT_TAILNET` | yes (10-tailscale) | tailnet name, i.e. `tailscale status --json \| jq -r .CurrentTailnet.Name` (usually your login name for a personal tailnet) |
| `WANT_SUFFIX` | no | MagicDNS suffix (`*.ts.net`); empty = not checked |
| `WANT_IP` | no | expected Tailscale IP; empty = not checked. A mismatch is only reported, never treated as broken |
| `GH_USER` | no | GitHub login gh should be signed in as; empty = any account (and the item passes if gh auth isn't set up) |

Until `WANT_HOST` and `WANT_TAILNET` are set, `10-tailscale` reports NEEDS HUMAN. If you don't use Tailscale, disable the item:
`touch /workspace/restore/items/10-tailscale/DISABLED`.

## Install
Requirements: bash, `jq`, `flock`, `timeout`, `setsid`, passwordless `sudo -n`, and `curl` (only for the tarball fallback).
```bash
git clone https://github.com/heyalchang/grokbot-box-heal.git /workspace/src/grokbot-box-heal   # OWNER = this repo's owner
cd /workspace/src/grokbot-box-heal && ./install.sh
$EDITOR /workspace/restore/config.env
```
`install.sh` is idempotent: re-run it after `git pull` to update. It copies scripts and items, creates `config.env` only if missing,
installs or replaces the `~/.bashrc` block between `# >>> box auto-restore >>>` and `# <<< box auto-restore <<<` (leaving the rest of
the file alone; a backup goes to `state/`), and takes the first package baseline if none exists. It never runs a login.
Options: `--no-hook`, `--no-baseline`. To try it in a scratch dir: `WORKSPACE=/tmp/x BASHRC=/tmp/x/bashrc ./install.sh`
(scripts then need `BOX_WORKSPACE=/tmp/x`; the hook sets that itself).

Re-installing re-copies kit files (including `NO_AGENT` flags) but never deletes your own items or `DISABLED` flags.
To uninstall the hook, delete the lines between (and including) the two markers.

## One-time human steps
These need a person. Agents must never do them, and must never relay a login link or code.

**Tailscale sign-in** (once per node; afterwards the state backup carries it across updates):
```bash
. /workspace/restore/config.env
/workspace/bin/tailscale-restore.sh --first-run; echo "exit=$?"   # installs binaries, starts tailscaled with an empty state; exits 2
sudo tailscale up --ssh --hostname="$WANT_HOST" --accept-dns=false --accept-routes=false
#   -> open the sign-in link it prints in YOUR browser and approve the node
/workspace/bin/tailscale-restore.sh; echo "exit=$?"               # expect 0; this also writes the first state backup
/workspace/restore/items/10-tailscale/check
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
only stops other Unix users. If that's not acceptable, skip the gh step, disable `30-gh-auth`, and/or limit what the node and token can
reach (Tailscale ACLs/tags, a fine-grained or narrowly scoped GitHub token). The scripts never print, log, or upload these
contents, and every `INSTRUCTIONS.md` forbids agents from doing so.

## How the runner works
`/workspace/bin/restore-all.sh [--caller NAME] [--only SUBSTR] [--no-agent] [--force-agent] [--quiet]`

For each `items/NN-name/` in order (names starting with two digits and a dash; `_template` is skipped):
1. Run `check` (60 s limit). Exit 0 = healthy, move on.
2. Otherwise run `restore` (600 s limit, stdin `/dev/null`), then `check` again.
3. If `restore` failed (exit other than 0, 2, 75), or exited 0 but `check` still fails, and the item has an `INSTRUCTIONS.md` and no
   `NO_AGENT` file, run the Grok CLI headless (`~/.grok/bin/grok -p ... --always-approve --max-turns 40`, 900 s timeout, at most
   once per 30 min per item), then `check` once more.
4. One summary line per item goes to stdout and `restore.log`. One item failing never stops the others.

### Exit codes (worst wins: 30 > 20 > 10 > 0)
| code | meaning | alert? |
|---|---|---|
| 0  | everything healthy, nothing done | no |
| 10 | something was restored (or a restore was already in progress elsewhere); all fine now | FYI |
| 20 | NEEDS HUMAN: an item needs a person (Tailscale NEEDS LOGIN, package drift, gh token rejected, config missing) | **yes** |
| 30 | FAILED: an item is still broken after restore + agent | **yes** |
| 75 | another runner holds the lock; nothing done | no |

`tailscale-restore.sh` on its own: 0 healthy/restored, 2 NEEDS LOGIN, 3 no sudo, 4 binaries unavailable, 5 tailscaled won't start,
6 still unhealthy, 75 busy. `restore-baseline-snapshot.sh`: 0 saved/no change, 10 saved with differences, 30 failed.

## The `~/.bashrc` hook
Runs above the interactive guard, so `bash -ilc` (agents), SSH and login shells all run it. Silent, scripts only:
- **Rate limit:** stamp `state/hook-last-run` holds the boot id. Younger than 15 min and same boot: nothing else happens (~1 ms).
  Otherwise it rewrites the stamp first (atomically, so concurrent shells skip), then:
- **New boot** (boot id differs): launches `restore-all.sh --caller bashrc --quiet` in the background at once.
- **Same boot:** `timeout 2 sudo -n tailscale status --json`; launches restore-all only if it is not `BackendState=Running` and
  `Self.Online=true`. A persistently broken box gets at most one run per 15 min.
- **Daily baseline:** if `state/baseline-last-run` is older than 24 h, touches it and runs `restore-baseline-snapshot.sh` in the
  background (after 5 s, so restore-all gets the lock first). On failure the stamp is back-dated so it retries in about 1 h.
- Loop guard: `RESTORE_ACTIVE` / `TS_RESTORE_ACTIVE` (set by the runner) disable the hook in shells the runner spawns.

## Suggested daily Grok Bot routine
The hook only fires when some shell starts, so add one Grok Bot routine, once a day, as the backstop and alert path. Example prompt:

> Daily box health check. Run `/workspace/bin/restore-all.sh --caller routine; echo "exit=$?"`. Then read the last 24 h of
> `/workspace/restore/restore.log`. If `/workspace/restore/state/baseline-last-run` is older than 26 h, run
> `/workspace/bin/restore-baseline-snapshot.sh --caller routine`. If the exit was 0, 10 or 75 and the log shows nothing new and
> alarming, stay silent. If it was 20 or 30, message me with one short paragraph: which item, what the summary line says, and what I
> need to do (for package drift, summarize the newest report in `/workspace/restore/state/drift/`). Never print secrets, never sign in
> to anything, never relay a login link or code, never install or remove packages unless I ask.

## Adding an item
1. `cp -r /workspace/restore/items/_template /workspace/restore/items/40-myname` (the number sets the order; use gaps of 10).
2. `check`: read-only, fast (60 s hard limit), exit 0 if healthy, print one short line saying what it saw.
3. `restore`: idempotent, non-interactive (stdin is `/dev/null`, 600 s limit), `sudo -n` for root, prefer offline copies kept under
   `/workspace` over the network. Exit `0` restored · `2` needs a human (no agent) · `75` busy, skip this round · anything else =
   failed (agent fallback).
4. `INSTRUCTIONS.md`: what healthy means, the steps, when to stop, and the hard rules (keep the template's rules section).
5. `chmod +x check restore`, then test: `/workspace/bin/restore-all.sh --only 40-myname --no-agent`.
6. `touch DISABLED` to pause an item; `touch NO_AGENT` to keep the Grok fallback away from it (e.g. alert-only items).

Env given to `check`/`restore`: `ITEM_NAME`, `ITEM_DIR`, `RESTORE_CALLER`, `RESTORE_LOG`, `RESTORE_CONFIG`, `BOX_WORKSPACE`,
`RESTORE_ACTIVE=1`. Read your own settings from `$RESTORE_CONFIG`. Items you add are never touched by `install.sh`
unless they share a name with a kit item.

## Rules every item follows
Never print, log, or copy keys, tokens, passwords, login links, or state/credential contents. No fresh logins and no minting
credentials. Keep durable copies in `/workspace`. More background: [docs/box-self-heal.md](docs/box-self-heal.md).

## License
MIT, see [LICENSE](LICENSE).
