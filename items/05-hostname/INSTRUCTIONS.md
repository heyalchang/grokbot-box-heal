# 05-hostname
Healthy = `hostname`, `/etc/hostname` and `/etc/hosts` all say `WANT_OS_HOSTNAME` (config.env; empty = this item is off and
passes), and no Chrome `SingletonLock` under `$HOME/chrome-profile/*/` carries another hostname. A computer update resets the
root-owned files, so the box comes back under the platform's generated name. `restore` adds the `/etc/hosts` entry first (so
`sudo` resolves the name), then sets the hostname, then repoints stale Chrome locks (same pid) so cold Chrome launches are not
refused with "profile in use by another computer". NO_AGENT is set: failures alert the owner. Never kill a running Chrome.
