#!/usr/bin/env bash
# restore-baseline-accept.sh: explicitly accept the CURRENT package set as today's baseline for item 200-package-drift.
# Run it ONLY when the box owner explicitly says to accept the current package set. Agents must never run it on their own.
# (Normally not needed: the daily snapshot absorbs drift into the next day's baseline by itself.)
#
# Usage: restore-baseline-accept.sh --reason "why" [--by WHO] [--state-dir DIR]
#   --reason     required free text (logged)
#   --by         who approved/ran it (default: $RESTORE_CALLER or $USER)
#   --state-dir  alt state root (default $BOX_WORKSPACE/restore/state; use a temp dir for tests)
# Effect: moves today's dated baseline (if any) to <state>/baseline-history/, re-runs restore-baseline-snapshot.sh so
# today's baseline is the live package list, clears the drift dedupe record, and logs who/why.
# Exit: the snapshot's exit code (0 / 10 / 30), or 64 on bad usage.
set -euo pipefail
export LC_ALL=C
WS=${BOX_WORKSPACE:-/workspace}
STATE=$WS/restore/state
REASON="" BY="${RESTORE_CALLER:-${USER:-unknown}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON=${2:-}; shift ;;
    --by) BY=${2:-}; shift ;;
    --state-dir) STATE=${2:-}; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
  shift
done
[ -n "${REASON// /}" ] || { echo "ERROR: --reason \"<text>\" is required" >&2; exit 64; }
REASON=$(printf '%s' "$REASON" | tr '\n\t' '  ')
BY=$(printf '%s' "$BY" | tr -cd 'A-Za-z0-9._@:-')
if [ "$STATE" = "$WS/restore/state" ]; then LOG=$WS/restore/restore.log; else LOG=$STATE/restore.log; fi
HIST=$STATE/baseline-history
DAY=$(date +%F); ts=$(date +%Y%m%dT%H%M%S); now=$(date '+%F %T %Z')
B=$STATE/baselines/packages-$DAY.txt
mkdir -p "$HIST" "$STATE/drift"
archived="(none: no baseline for $DAY yet)"
if [ -e "$B" ]; then archived="$HIST/packages-$DAY-replaced-$ts.txt"; mv -f "$B" "$archived"; fi
set +e
"$(dirname "$0")/restore-baseline-snapshot.sh" --caller "accept:$BY" --state-dir "$STATE"; rc=$?
set -e
rm -f "$STATE/drift/last-reported"
line="$now [baseline-accept by $BY] snapshot rc=$rc; accepted current packages as $B; archived old to $archived; dedupe cleared; reason: $REASON"
echo "$line" >>"$HIST/ACCEPT-LOG.txt"
echo "$line" >>"$LOG"
echo "$line"
exit "$rc"
