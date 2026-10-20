# >>> box auto-restore >>>
# Self-heal trigger, scripts only (see @WS@/restore/README.md). Managed by grokbot-box-restore install.sh; edits here are
# replaced on the next install. Sits above the interactive guard so login, agent (`bash -ilc`) and SSH shells all run it.
# Silent; costs ~1 ms when the stamp is fresh. At most once per 15 min (stamp hook-last-run, which holds the boot id):
# check Tailscale is Running+Online; launch restore-all.sh if not, or at once on a new boot. Daily baseline if >24h old.
if [ -z "${RESTORE_ACTIVE:-}${TS_RESTORE_ACTIVE:-}" ] && [ -x "@WS@/bin/restore-all.sh" ]; then
  __w="@WS@"; __s=$__w/restore/state/hook-last-run; __b=$__w/restore/state/baseline-last-run; __rb=; __lb=
  read -r __rb 2>/dev/null </proc/sys/kernel/random/boot_id; read -r __lb 2>/dev/null <"$__s"
  if [ "$__rb" != "$__lb" ] || [ -z "$(find "$__s" -mmin -15 2>/dev/null)" ]; then
    [ -d "$__w/restore/state" ] || mkdir -p "$__w/restore/state" 2>/dev/null
    { echo "$__rb" >"$__s.$$" && mv -f "$__s.$$" "$__s"; } 2>/dev/null   # claim the 15-min slot first (atomic) so concurrent shells skip
    if { [ "$__rb" != "$__lb" ] || ! timeout 2 sudo -n /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null \
         | jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null 2>&1; } && sudo -n true 2>/dev/null; then
      ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; BOX_WORKSPACE=$__w setsid nohup "$__w/bin/restore-all.sh" --caller bashrc --quiet </dev/null >/dev/null 2>&1 & )
    fi
    if [ -x "$__w/bin/restore-baseline-snapshot.sh" ] && [ -z "$(find "$__b" -mmin -1440 2>/dev/null)" ]; then
      touch "$__b" 2>/dev/null   # on failure (rc 30) back-date it so the next try is ~1 h later; sleep lets restore-all take the lock first
      ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; BOX_WORKSPACE=$__w setsid nohup bash -c 'sleep 5; "$1/bin/restore-baseline-snapshot.sh" --caller bashrc; [ $? -lt 30 ] || touch -d "-23 hours" "$0"' "$__b" "$__w" </dev/null >/dev/null 2>&1 & )
    fi
  fi
  unset __w __s __b __rb __lb
fi
# <<< box auto-restore <<<
