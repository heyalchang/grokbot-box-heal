#!/usr/bin/env bash
# restore-all.sh: general self-heal and periodic job runner for the box.
#  1. Walks $BOX_WORKSPACE/restore/items/NNN-name/ in order under .restore-all.lock:
#     check -> (restore -> check) -> (agent fallback -> check).
#  2. Releases .restore-all.lock, then walks $BOX_WORKSPACE/restore/jobs/NNN-name/ in order under .restore-jobs.lock:
#     runs ./run when at least INTERVAL seconds have elapsed since the last run (or when matched by --only).
# One item or job failing never stops the others.
#
# Usage: restore-all.sh [--caller NAME] [--only SUBSTR] [--no-agent] [--force-agent] [--no-jobs] [--quiet]
# Items containing a NO_AGENT file (and all jobs) never get the Grok fallback (even with --force-agent).
# Exit:  0  everything healthy, nothing done (or only routine jobs ran with rc 0)
#        10 something was restored or a job reported a change (rc 10/11); all fine now
#        20 NEEDS HUMAN: some item or job needs a person (e.g. NEEDS LOGIN, package drift); alert
#        30 FAILED: some item is still broken after restore + agent fallback, or a job failed; alert
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
JOBS=$ROOT/jobs
STATE=$ROOT/state
export RESTORE_CONFIG=${RESTORE_CONFIG:-$ROOT/config.env}
export RESTORE_LOG=$ROOT/restore.log
GROK=${GROK_BIN:-$HOME/.grok/bin/grok}
AGENT_LOG=$ROOT/agent-restore.log
AGENT_MIN_GAP=${RESTORE_AGENT_MIN_GAP:-1800}       # seconds between agent runs per item
AGENT_TIMEOUT=${RESTORE_AGENT_TIMEOUT:-900}
CHECK_TIMEOUT=60 RESTORE_TIMEOUT=600 JOB_TIMEOUT=600

CALLER=manual ONLY="" NO_AGENT=0 FORCE_AGENT=0 NO_JOBS=0 QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --caller) CALLER=$2; shift ;;
    --only) ONLY=$2; shift ;;
    --no-agent) NO_AGENT=1 ;;
    --force-agent) FORCE_AGENT=1 ;;
    --no-jobs) NO_JOBS=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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
[ "$(stat -c %s "$RESTORE_LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$RESTORE_LOG" "$RESTORE_LOG.1"   # rotate at 1 MB, one old copy; under the lock so no other run's line counts shift

WORST=0
bump() { [ "$1" -gt "$WORST" ] && WORST=$1; return 0; }
run_check() { CHECK_OUT=$(cd "$1" && ITEM_DIR=$1 ITEM_NAME=$2 timeout "$CHECK_TIMEOUT" ./check </dev/null 2>&1 7>&- | oneline); return "${PIPESTATUS[0]}"; }

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
      </dev/null 2>&1 7>&-); arc=$?
    echo; echo "===== agent exit=$arc ====="
  } >>"$AGENT_LOG" 2>&1
  return 0
}

# Pass 1: deterministic check/restore for every item (fast; a slow agent never delays other items).
# Pass 2: agent fallback, one item at a time, only for items whose restore failed.
NEED_AGENT=()     # entries: "dir|name|rrc|why"
n=0
for dir in "$ITEMS"/[0-9][0-9][0-9]-*/; do
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
    rout=$(cd "$dir" && ITEM_DIR=$dir ITEM_NAME=$name timeout "$RESTORE_TIMEOUT" ./restore </dev/null 2>&1 7>&- | oneline); rrc=${PIPESTATUS[0]}
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

cat /proc/sys/kernel/random/boot_id >"$STATE/last-boot-id.tmp" 2>/dev/null && mv -f "$STATE/last-boot-id.tmp" "$STATE/last-boot-id"
exec 7>&-   # release .restore-all.lock before running periodic jobs so jobs (e.g. baseline snapshot) can acquire it normally

# Pass 3: periodic jobs in $JOBS/NNN-name/ (INTERVAL + run). Skipped on --caller update or --no-jobs.
if [ "$CALLER" != update ] && [ "$NO_JOBS" != 1 ] && [ -d "$JOBS" ]; then
  exec 8>>"$STATE/.restore-jobs.lock"
  if flock -n 8; then
    for jdir in "$JOBS"/[0-9][0-9][0-9]-*/; do
      jdir=${jdir%/}; jname=$(basename "$jdir")
      [ -d "$jdir" ] || continue
      if [ -n "$ONLY" ] && [[ "$jname" != *"$ONLY"* ]]; then continue; fi
      if [ -e "$jdir/DISABLED" ]; then [ -n "$ONLY" ] && { n=$((n + 1)); say "job $jname: skipped (DISABLED)"; }; continue; fi
      int=$(tr -d ' \t\r\n' <"$jdir/INTERVAL" 2>/dev/null || true)
      if ! [[ "$int" =~ ^[0-9]+$ ]] || [ "$int" -lt 60 ]; then
        n=$((n + 1)); say "job $jname: FAILED (INTERVAL in $jdir/INTERVAL must be a whole number >= 60; got '$int')"; bump 30; continue
      fi
      if [ ! -x "$jdir/run" ]; then
        n=$((n + 1)); say "job $jname: FAILED (run script missing or not executable)"; bump 30; continue
      fi
      stamp="$STATE/job-last-run.$jname"; now=$(date +%s); last_ts=0; last_rc=0; last_out=""
      read -r last_ts last_rc last_out 2>/dev/null <"$stamp" || true
      case $last_ts in ''|*[!0-9]*) last_ts=0 ;; esac
      case $last_rc in ''|*[!0-9]*) last_rc=0 ;; esac
      if [ -z "$ONLY" ] && [ $((now - last_ts)) -lt "$int" ] && [ "$last_ts" -le "$now" ]; then
        case $last_rc in
          0|10|11) ;;
          2|20) n=$((n + 1)); say "job $jname: NEEDS HUMAN (last run $((now - last_ts))s ago exited $last_rc${last_out:+: $last_out})"; bump 20 ;;
          *)    n=$((n + 1)); say "job $jname: FAILED (last run $((now - last_ts))s ago exited $last_rc${last_out:+: $last_out})"; bump 30 ;;
        esac
        continue
      fi
      n=$((n + 1))
      jout=$(cd "$jdir" && JOB_DIR=$jdir JOB_NAME=$jname timeout "$JOB_TIMEOUT" ./run </dev/null 2>&1 8>&- | oneline); jrc=${PIPESTATUS[0]}
      if [ "$jrc" -eq 75 ]; then say "job $jname: busy (skipped)"; continue; fi
      printf '%s %s %s\n' "$now" "$jrc" "$jout" >"$stamp.tmp" && mv -f "$stamp.tmp" "$stamp"
      case $jrc in
        0)     say "job $jname: ok${jout:+ - $jout}" ;;
        10|11) say "job $jname: ${jout:-done (rc=$jrc)}"; bump 10 ;;
        2|20)  say "job $jname: NEEDS HUMAN (rc=$jrc${jout:+: $jout})"; bump 20 ;;
        *)     say "job $jname: FAILED (rc=$jrc${jout:+: $jout})"; bump 30 ;;
      esac
    done
    exec 8>&-
  else
    log "another job run holds .restore-jobs.lock; skipping jobs"
  fi
fi

[ "$n" -eq 0 ] && say "restore-all: no items matched"
case $WORST in 0) w="all healthy" ;; 10) w="restored" ;; 20) w="NEEDS HUMAN" ;; *) w="FAILED" ;; esac
say "restore-all: exit $WORST ($w; $n item(s))"
exit "$WORST"
