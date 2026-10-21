# >>> box auto-restore >>>
# Self-heal trigger, scripts only (see @WS@/restore/README.md). Managed by grokbot-box-heal install.sh; edits here are
# replaced on the next install. Sits above the interactive guard so login, agent (`bash -ilc`) and SSH shells all run it.
# At most once per 15 min, or at once on a new boot, launch restore-all.sh in the background. restore-all's items decide what
# (if anything) needs doing; the hook itself checks nothing.
# No fork when the stamp is fresh: stamp hook-last-run holds "<boot id> <epoch>", compared with $EPOCHSECONDS (bash >= 5;
# without it, date +%s, one fork, and the 15-min limit still holds). An unreadable boot id is stored as "-" so it still
# rate-limits instead of looking like a new boot every shell. A missing or unusable epoch is stale, so a bad stamp cannot
# stop the launches or abort the shell. Each launch appends one line to @WS@/restore/hook.log (rotated at 1 MB to
# hook.log.1); a failed write never breaks the shell. Silent on the terminal.
if [ -z "${RESTORE_ACTIVE:-}${TS_RESTORE_ACTIVE:-}" ] && [ -x "@WS@/bin/restore-all.sh" ]; then
  __w="@WS@"; __s=$__w/restore/state/hook-last-run; __l=$__w/restore/hook.log
  __rb=; __lb=; __le=; __d=
  read -r __rb 2>/dev/null </proc/sys/kernel/random/boot_id || true; read -r __lb __le 2>/dev/null <"$__s" || true
  [ -n "$__rb" ] || __rb=-   # blank boot id used to match an empty stamp; a leading space would not, and every shell looked new
  case $__le in
    ''|*[!0-9]*) __le=0 ;;   # stock kit stamp (no epoch) or non-numeric: stale
    *) if [ "${#__le}" -gt 18 ]; then __le=0; else __le=$((10#${__le})); fi ;;   # base 10; oversized would wrap and could skip
  esac
  __now=${EPOCHSECONDS:-}; if [ -z "$__now" ]; then __now=$(date +%s 2>/dev/null || true); fi
  case $__now in ''|*[!0-9]*) __now=0 ;; esac   # no clock at all: stale, and hook.log shows every launch
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
    { [ -z "$(find "$__l" -size +1024k 2>/dev/null)" ] || mv -f "$__l" "$__l.1" || true
      printf '%(%F %T %Z)T [hook pid %s] %s\n' -1 "$$" "$__d" >>"$__l" || true; } 2>/dev/null   # a log failure never breaks the shell
  fi
  unset __w __s __l __rb __lb __le __now __d
fi
# <<< box auto-restore <<<
