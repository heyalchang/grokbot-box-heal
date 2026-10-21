# Changelog

Newest first, one plain-English line per version. `selfheal-update.sh` prints these lines, so keep each to one line.

- 1.3.0: the ~/.bashrc hook no longer forks when it has checked recently, and logs one line per real check to restore/hook.log (rotated at 1 MB)
- 1.2.0: Tailscale SSH is now a setting (TAILSCALE_SSH, default on)
- 1.1.0: adds optional weekly self-update (UPDATE_MODE=auto|ask|off in config.env; bin/selfheal-update.sh).
- 1.0.0: initial release: restore runner, ~/.bashrc hook, Tailscale restore, package drift alerts, gh auth restore.
