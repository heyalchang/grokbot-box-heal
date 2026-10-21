# >>> box auto-restore >>>
# Self-heal trigger, scripts only (see @WS@/restore/README.md). Managed by grokbot-box-heal install.sh; edits here are
# replaced on the next install. Sits above the interactive guard so login, agent (`bash -ilc`) and SSH shells all run it.
# No fork when the stamp is fresh: stamp hook-last-run holds "<boot id> <epoch>", compared with $EPOCHSECONDS (bash >= 5;
# without it every shell counts as stale, which hook.log then shows). A missing or unusable epoch is stale too, so a bad
# stamp cannot stop the checks or abort the shell. Each real check appends one line to
# @WS@/restore/hook.log (rotated at 1 MB to hook.log.1); a failed write never breaks the shell. Silent on the terminal.
# At most once per 15 min, or at once on a new boot: check Tailscale is Running+Online; launch restore-all.sh if not, or at
# once on a new boot. Daily baseline if >24h old.
if [ -z "${RESTORE_ACTIVE:-}${TS_RESTORE_ACTIVE:-}" ] && [ -x "@WS@/bin/restore-all.sh" ]; then
  __w="@WS@"; __s=$__w/restore/state/hook-last-run; __b=$__w/restore/state/baseline-last-run; __l=$__w/restore/hook.log
  __rb=; __lb=; __le=; __ts=; __d=
  read -r __rb 2>/dev/null </proc/sys/kernel/random/boot_id || true; read -r __lb __le 2>/dev/null <"$__s" || true
  case $__le in
    ''|*[!0-9]*) __le=0 ;;   # stock kit stamp (no epoch) or non-numeric: stale
    *) if [ "${#__le}" -gt 18 ]; then __le=0; else __le=$((10#${__le})); fi ;;   # base 10; oversized would wrap and could skip
  esac
  if [ "$__rb" != "$__lb" ] || [ -z "${EPOCHSECONDS:-}" ] || [ "$((EPOCHSECONDS - __le))" -ge 900 ] || [ "$__le" -gt "$EPOCHSECONDS" ]; then
    [ -d "$__w/restore/state" ] || mkdir -p "$__w/restore/state" 2>/dev/null || true
    if echo "$__rb ${EPOCHSECONDS:-0}" >"$__s.$$" 2>/dev/null; then mv -f "$__s.$$" "$__s" 2>/dev/null || true; fi   # claim the 15-min slot first (atomic) so concurrent shells skip
    if [ "$__rb" != "$__lb" ]; then
      __d="boot=new ts=not-checked"
    else
      __ts=$(timeout 2 sudo -n /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null \
             | jq -r '"\(.BackendState) online=\(.Self.Online)"' 2>/dev/null || true)
      __d="boot=same ts=${__ts:-unknown}"
    fi
    if [ "$__ts" = "Running online=true" ]; then
      __d="$__d -> nothing"
    elif sudo -n true 2>/dev/null; then
      ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; BOX_WORKSPACE=$__w setsid nohup "$__w/bin/restore-all.sh" --caller bashrc --quiet </dev/null >/dev/null 2>&1 & )
      __d="$__d -> launched restore-all"
    else
      __d="$__d -> restore-all needed but sudo -n failed; not launched"
    fi
    if [ -x "$__w/bin/restore-baseline-snapshot.sh" ] && [ -z "$(find "$__b" -mmin -1440 2>/dev/null)" ]; then
      touch "$__b" 2>/dev/null || true   # on failure (rc 30) back-date it so the next try is ~1 h later; sleep lets restore-all take the lock first
      ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; BOX_WORKSPACE=$__w setsid nohup bash -c 'sleep 5; "$1/bin/restore-baseline-snapshot.sh" --caller bashrc; [ $? -lt 30 ] || touch -d "-23 hours" "$0"' "$__b" "$__w" </dev/null >/dev/null 2>&1 & )
      __d="$__d, baseline launched"
    fi
    { [ -z "$(find "$__l" -size +1024k 2>/dev/null)" ] || mv -f "$__l" "$__l.1" || true
      printf '%(%F %T %Z)T [hook pid %s] %s\n' -1 "$$" "$__d" >>"$__l" || true; } 2>/dev/null   # a log failure never breaks the shell
  fi
  unset __w __s __b __l __rb __lb __le __ts __d
fi
# <<< box auto-restore <<<
