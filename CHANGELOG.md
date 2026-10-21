# Changelog

Newest first, one plain-English line per version. `selfheal-update.sh` prints these lines, so keep each to one line.

- 1.5.0: items renumbered with gaps of 50 (050-hostname, 100-tailscale, 150-tailscale-online, 200-package-drift, 250-gh-auth, 300-bashrc-hook); install.sh retires the old-numbered copies into state/
- 1.4.0: the hook launches restore-all every 15 min (no inline Tailscale check); restore.log rotates at 1 MB; new items 050-hostname, 150-tailscale-online (the ss -K unstick plus its watchdog loop) and 300-bashrc-hook (puts the hook back after a computer update); install.sh --hook-only
- 1.3.0: the ~/.bashrc hook no longer forks when it has checked recently, and logs one line per real check to restore/hook.log (rotated at 1 MB)
- 1.2.0: Tailscale SSH is now a setting (TAILSCALE_SSH, default on)
- 1.1.0: adds optional weekly self-update (UPDATE_MODE=auto|ask|off in config.env; bin/selfheal-update.sh).
- 1.0.0: initial release: restore runner, ~/.bashrc hook, Tailscale restore, package drift alerts, gh auth restore.
