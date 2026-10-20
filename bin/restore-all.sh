#!/usr/bin/env bash
# restore-all.sh: general self-heal runner for the box. Walks $BOX_WORKSPACE/restore/items/NN-name/ in order:
# check -> (restore -> check) -> (agent fallback -> check). One item failing never stops the others.
#
# Usage: restore-all.sh [--caller NAME] [--only ITEM] [--no-agent] [--force-agent] [--quiet]
# Items containing a NO_AGENT file never get the Grok fallback (even with --force-agent).
# Exit:  0  everything healthy, nothing done
#        10 something was restored (or a restore was already in progress elsewhere); all fine now
#        20 NEEDS HUMAN: some item needs a person (e.g. NEEDS LOGIN); alert
#        30 FAILED: some item is still broken after restore + agent fallback; alert
#        75 another restore-all run holds the lock; nothing done (not an alert)
# Worst code wins: 30 > 20 > 10 > 0.
# Env: BOX_WORKSPACE (default /workspace), RESTORE_CONFIG (default $BOX_WORKSPACE/restore/config.env), GROK_BIN.
set -uo pipefail
export HOME=${HOME:-/home/box}
export BOX_WORKSPACE=${BOX_WORKSPACE:-/workspace}
export PATH=$HOME/.grok/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export RESTORE_ACTIVE=1 TS_RESTORE_ACTIVE=1          # loop guard for the ~/.bashrc trigger (agent shells etc.)

ROOT=$BOX_WORKSPACE/restore
ITEMS=$ROOT/items
STATE=$ROOT/state
export RESTORE_CONFIG=${RESTORE_CONFIG:-$ROOT/config.env}
export RESTORE_LOG=$ROOT/restore.log
GROK=${GROK_BIN:-$HOME/.grok/bin/grok}
AGENT_LOG=$ROOT/agent-restore.log
AGENT_MIN_GAP=${RESTORE_AGENT_MIN_GAP:-1800}       # seconds between agent runs per item
AGENT_TIMEOUT=${RESTORE_AGENT_TIMEOUT:-900}
CHECK_TIMEOUT=60 RESTORE_TIMEOUT=600

CALLER=manual ONLY="" NO_AGENT=0 FORCE_AGENT=0 QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --caller) CALLER=$2; shift ;;
    --only) ONLY=$2; shift ;;
    --no-agent) NO_AGENT=1 ;;
    --force-agent) FORCE_AGENT=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
  shift
done
export RESTORE_CALLER=$CALLER
mkdir -p "$STATE"

log() { printf '%s [restore-all pid %s %s] %s\n' "$(date '+%F %T %Z')" "$$" "$CALLER" "$*" >>"$RESTORE_LOG"; }
say() { log "$*"; [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
oneline() { tr '\n' ' ' | sed -E 's#https?://[^ ]+#<url>#g; s/  +/ /g; s/ +$//' | cut -c1-240; }

exec 7>>"$STATE/.restore-all.lock"
if [ "$CALLER" = bashrc ]; then W=0; else W=${RESTORE_LOCK_WAIT:-120}; fi
if ! flock -w "$W" 7; then log "another restore-all run holds the lock; skipping"; [ "$QUIET" = 1 ] || echo "restore-all: busy (another run in progress)"; exit 75; fi

WORST=0
bump() { [ "$1" -gt "$WORST" ] && WORST=$1; return 0; }
run_check() { CHECK_OUT=$(cd "$1" && ITEM_DIR=$1 ITEM_NAME=$2 timeout "$CHECK_TIMEOUT" ./check </dev/null 2>&1 | oneline); return "${PIPESTATUS[0]}"; }

agent_fallback() { # agent_fallback <dir> <name> <restore_rc>  -> 0 if agent ran
  local dir=$1 name=$2 rrc=$3 stamp="$STATE/agent-last-run.$2" now last
  [ -e "$dir/NO_AGENT" ] && { log "$name: NO_AGENT flag set; never invoking agent"; return 1; }
  [ -f "$dir/INSTRUCTIONS.md" ] || { log "$name: no INSTRUCTIONS.md; no agent fallback"; return 1; }
  [ -x "$GROK" ] || { log "$name: grok CLI missing at $GROK; no agent fallback"; return 1; }
  now=$(date +%s); last=$(cat "$stamp" 2>/dev/null || echo 0)
  if [ "$FORCE_AGENT" != 1 ] && [ $((now - last)) -lt "$AGENT_MIN_GAP" ]; then
    log "$name: agent ran $((now - last))s ago (<${AGENT_MIN_GAP}s); not re-invoking"; return 1
  fi
  echo "$now" >"$stamp"
  AGENT_PRE=$(wc -l <"$RESTORE_LOG" 2>/dev/null || echo 0)
  log "$name: invoking headless grok agent with $dir/INSTRUCTIONS.md (restore rc=$rrc; output -> $AGENT_LOG)"
  {
    echo "===== $(date '+%F %T %Z') agent run: item=$name restore_rc=$rrc caller=$CALLER ====="
    (cd "$dir" && timeout "$AGENT_TIMEOUT" "$GROK" --always-approve --max-turns 40 --disable-web-search \
      -p "You are restoring one item on this box: $name (folder $dir). Its restore script just exited with code $rrc. Read $dir/INSTRUCTIONS.md and follow it exactly. Expected values are in $RESTORE_CONFIG. Never print secrets, never log in fresh, never mint credentials; if a human is needed, log NEEDS HUMAN and stop." \
      </dev/null 2>&1); arc=$?
    echo; echo "===== agent exit=$arc ====="
  } >>"$AGENT_LOG" 2>&1
  return 0
}

# Pass 1: deterministic check/restore for every item (fast; a slow agent never delays other items).
# Pass 2: agent fallback, one item at a time, only for items whose restore failed.
NEED_AGENT=()     # entries: "dir|name|rrc|why"
n=0
for dir in "$ITEMS"/[0-9][0-9]-*/; do
  dir=${dir%/}; name=$(basename "$dir")
  [ -d "$dir" ] || continue
  if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then continue; fi
  n=$((n + 1))
  if [ -e "$dir/DISABLED" ]; then say "$name: skipped (DISABLED)"; continue; fi
  item_no_agent=$NO_AGENT; fa=$FORCE_AGENT
  if [ -e "$dir/NO_AGENT" ]; then item_no_agent=1; fa=0; fi   # item opts out of the Grok fallback entirely
  if [ ! -x "$dir/check" ]; then say "$name: FAILED (check script missing or not executable)"; bump 30; continue; fi

  if run_check "$dir" "$name" && [ "$fa" != 1 ]; then
    say "$name: healthy - $CHECK_OUT"; continue
  fi
  why=$CHECK_OUT
  log "$name: check failed: $why"

  rrc=1; rout="(no restore script)"
  if [ -x "$dir/restore" ]; then
    rout=$(cd "$dir" && ITEM_DIR=$dir ITEM_NAME=$name timeout "$RESTORE_TIMEOUT" ./restore </dev/null 2>&1 | oneline); rrc=${PIPESTATUS[0]}
  fi
  log "$name: restore rc=$rrc${rout:+ - $rout}"
  if [ "$rrc" -eq 2 ]; then say "$name: NEEDS HUMAN (restore rc=2${rout:+: $rout}; was: $why)"; bump 20; continue; fi
  if [ "$rrc" -eq 75 ]; then say "$name: busy (restore already in progress elsewhere; was: $why)"; bump 10; continue; fi
  if [ "$rrc" -eq 0 ] && [ "$fa" != 1 ] && run_check "$dir" "$name"; then
    say "$name: restored - $CHECK_OUT (was: $why)"; bump 10; continue
  fi
  [ "$rrc" -eq 0 ] && log "$name: restore exited 0 but check still fails: $CHECK_OUT"
  if [ "$item_no_agent" = 1 ]; then say "$name: FAILED (restore rc=$rrc; check: $CHECK_OUT; no agent fallback)"; bump 30; continue; fi
  NEED_AGENT+=("$dir|$name|$rrc|$why")
done

for entry in "${NEED_AGENT[@]}"; do
  IFS='|' read -r dir name rrc why <<<"$entry"
  if agent_fallback "$dir" "$name" "$rrc"; then
    if run_check "$dir" "$name"; then say "$name: restored by agent - $CHECK_OUT (was: $why)"; bump 10; continue; fi
    if tail -n +"$((AGENT_PRE + 1))" "$RESTORE_LOG" | grep -q "NEEDS HUMAN\|NEEDS LOGIN"; then
      say "$name: NEEDS HUMAN (agent reported; check: $CHECK_OUT)"; bump 20; continue
    fi
  elif run_check "$dir" "$name"; then
    say "$name: restored (healthy on re-check) - $CHECK_OUT (was: $why)"; bump 10; continue
  fi
  say "$name: FAILED (restore rc=$rrc; check: $CHECK_OUT)"; bump 30
done

[ "$n" -eq 0 ] && say "restore-all: no items matched"
cat /proc/sys/kernel/random/boot_id >"$STATE/last-boot-id.tmp" 2>/dev/null && mv -f "$STATE/last-boot-id.tmp" "$STATE/last-boot-id"
case $WORST in 0) w="all healthy" ;; 10) w="restored" ;; 20) w="NEEDS HUMAN" ;; *) w="FAILED" ;; esac
say "restore-all: exit $WORST ($w; $n item(s))"
exit "$WORST"
