#!/usr/bin/env bash
# restore-hook.sh: sourced by the 3-line ~/.bashrc block on login, agent (`bash -ilc`) and SSH shells.
# At most once per 15 min, or at once on a new boot, launches restore-all.sh in the background.
# No fork when the stamp is fresh: stamp hook-last-run holds "<boot id> <epoch>", compared with $EPOCHSECONDS (bash >= 5;
# without it, date +%s, one fork, and the 15-min limit still holds). An unreadable boot id is stored as "-" so it still
# rate-limits instead of looking like a new boot every shell. A missing or unusable epoch is stale, so a bad stamp cannot
# stop the launches or abort the shell. Each launch appends one line to $WS/restore/restore.log (rotated by restore-all
# under its lock); a failed write never breaks the shell. Silent on the terminal.
__w=${BOX_WORKSPACE:-${BASH_SOURCE[0]%/bin/restore-hook.sh}}
if [ -z "${RESTORE_ACTIVE:-}" ] && [ -x "$__w/bin/restore-all.sh" ]; then
  __s=$__w/restore/state/hook-last-run; __l=$__w/restore/restore.log
  __rb=; __lb=; __le=; __d=
  read -r __rb 2>/dev/null </proc/sys/kernel/random/boot_id || true; read -r __lb __le 2>/dev/null <"$__s" || true
  [ -n "$__rb" ] || __rb=-   # blank boot id used to match an empty stamp; a leading space would not, and every shell looked new
  case $__le in
    ''|*[!0-9]*) __le=0 ;;   # stock kit stamp (no epoch) or non-numeric: stale
    *) if [ "${#__le}" -gt 18 ]; then __le=0; else __le=$((10#${__le})); fi ;;   # base 10; oversized would wrap and could skip
  esac
  __now=${EPOCHSECONDS:-}; if [ -z "$__now" ]; then __now=$(date +%s 2>/dev/null || true); fi
  case $__now in ''|*[!0-9]*) __now=0 ;; esac   # no clock at all: stale, and restore.log shows every launch
  if [ "$__rb" != "$__lb" ] || [ "$__now" = 0 ] || [ "$((__now - __le))" -ge 900 ] || [ "$__le" -gt "$__now" ]; then
    [ -d "$__w/restore/state" ] || mkdir -p "$__w/restore/state" 2>/dev/null || true
    if echo "$__rb $__now" >"$__s.$$" 2>/dev/null; then mv -f "$__s.$$" "$__s" 2>/dev/null || true; fi   # claim the 15-min slot first (atomic) so concurrent shells skip
    if [ "$__rb" != "$__lb" ]; then __d="boot=new"; else __d="boot=same"; fi
    if sudo -n true 2>/dev/null; then
      ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; BOX_WORKSPACE=$__w setsid nohup "$__w/bin/restore-all.sh" --caller bashrc --quiet </dev/null >/dev/null 2>&1 & )
      __d="$__d -> launched restore-all"
    else
      __d="$__d -> sudo -n failed; restore-all not launched"
    fi
    printf '%(%F %T %Z)T [hook pid %s] %s\n' -1 "$$" "$__d" >>"$__l" 2>/dev/null || true   # a log failure never breaks the shell
  fi
  unset __s __l __rb __lb __le __now __d
fi
unset __w
