#!/usr/bin/env bash
# restore-baseline-snapshot.sh: daily package baseline for restore item 200-package-drift.
# Run once a day, normally by the ~/.bashrc hook:  $BOX_WORKSPACE/bin/restore-baseline-snapshot.sh --caller bashrc
# Each run:
#  a) capture the package list (dpkg-query -W -f='${Package}\t${Version}\n', LC_ALL=C sorted)
#  b) diff vs the newest existing baseline dated before today; if different, write state/drift/overnight-YYYY-MM-DD.txt
#     (so drift that the new baseline absorbs is still on record)
#  c) save state/baselines/packages-YYYY-MM-DD.txt read-only (444); an existing file for that date is kept (idempotent)
#  d) point state/packages-baseline.txt (symlink) at the newest baseline
#  e) keep the newest 365 dated baselines; delete only older packages-YYYY-MM-DD.txt files in baselines/
#  f) holds the same flock as restore-all.sh (state/.restore-all.lock)
# Exit: 0 saved, no change vs previous baseline (also: first baseline, or today's already existed)
#       10 saved and differences were found (report path printed on stdout)
#       1 failed
# Test options: --state-dir DIR (alt state root), --date YYYY-MM-DD (pretend date), --keep N; env PKG_DRIFT_CURRENT=<file>
# Env: BOX_WORKSPACE (default /workspace)
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C
WS=${BOX_WORKSPACE:-/workspace}
CALLER=manual STATE=$WS/restore/state DAY=$(date +%F) KEEP=365
while [ $# -gt 0 ]; do
  case "$1" in
    --caller) CALLER=${2:-}; shift ;;
    --state-dir) STATE=${2:-}; shift ;;
    --date) DAY=${2:-}; shift ;;
    --keep) KEEP=${2:-}; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$DAY" >/dev/null 2>&1 || { echo "bad --date $DAY" >&2; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ ]] && [ "$KEEP" -ge 1 ] || { echo "bad --keep $KEEP" >&2; exit 1; }
if [ "$STATE" = "$WS/restore/state" ]; then LOG=$WS/restore/restore.log; else LOG=$STATE/restore.log; fi
log() { printf '%s [baseline-snapshot pid %s %s] %s\n' "$(date '+%F %T %Z')" "$$" "$CALLER" "$*" >>"$LOG"; }
fail() { log "FAILED: $*"; echo "FAILED: $*" >&2; exit 1; }

mkdir -p "$STATE/baselines" "$STATE/drift" || { echo "FAILED: cannot create dirs under $STATE" >&2; exit 1; }
exec 7>>"$STATE/.restore-all.lock"
flock -w 600 7 || fail "could not get lock $STATE/.restore-all.lock within 600s"

export PKG_DRIFT_STATE=$STATE PKG_DRIFT_DIR=$STATE/drift
unset PKG_DRIFT_BASELINE
. "$WS/restore/items/200-package-drift/lib.sh" || fail "cannot source lib.sh"
B="$STATE/baselines/packages-$DAY.txt"
cur=$(current_packages); [ -n "$cur" ] || fail "package list empty (dpkg-query failed?)"
n=$(printf '%s\n' "$cur" | grep -c .)

rc=0; report=""
if [ -e "$B" ]; then
  log "baseline for $DAY already exists ($B); kept unchanged"
  echo "kept existing $B"
else
  prev=$(ls "$STATE"/baselines/packages-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].txt 2>/dev/null | sort | awk -v b="$B" '$0 < b' | tail -n 1)
  tmpcur=$(mktemp) || fail mktemp; printf '%s\n' "$cur" >"$tmpcur"
  if [ -n "$prev" ]; then
    compute_drift "$prev" "$tmpcur" || { rm -f "$tmpcur"; fail "diff failed: $DRIFT_ERR"; }
    if [ $((NM + NE + NC)) -gt 0 ]; then
      report="$STATE/drift/overnight-$DAY.txt"; [ -e "$report" ] && report="$STATE/drift/overnight-$DAY-$(date +%H%M%S).txt"
      {
        echo "# Overnight package drift $(basename "$prev") -> packages-$DAY.txt (captured $(date '+%F %T %Z'), caller $CALLER)"
        echo "# summary: $NM missing, $NE extra, $NC version change(s). The new baseline absorbs these; this report keeps them on record."
        write_diff_body
      } >"$report"
      rc=10
    fi
  fi
  rm -f "$tmpcur"
  tmp="$B.tmp.$$"
  {
    echo "# packages-$DAY.txt: daily package baseline for restore item 200-package-drift"
    echo "# captured: $(date '+%F %T %Z') by restore-baseline-snapshot.sh (caller $CALLER); previous: ${prev:+$(basename "$prev")}${prev:-none}"
    echo "# format: name<TAB>version, from: dpkg-query -W -f='\${Package}\t\${Version}\n' (LC_ALL=C sorted); read-only, never edited"
    printf '%s\n' "$cur"
  } >"$tmp" && chmod 444 "$tmp" && mv -f "$tmp" "$B" || { rm -f "$tmp"; fail "could not write $B"; }
  log "saved $B ($n pkgs; previous ${prev:-none})${report:+; differences: $NM missing, $NE extra, $NC version changes -> $report}"
  echo "saved $B ($n pkgs)"
fi

# d) symlink -> newest
newest=$(newest_baseline)
[ -n "$newest" ] || fail "no baseline found after save"
ln -sfn "baselines/$(basename "$newest")" "$STATE/packages-baseline.txt.tmp" && mv -Tf "$STATE/packages-baseline.txt.tmp" "$STATE/packages-baseline.txt" \
  || fail "could not update symlink $STATE/packages-baseline.txt"

# e) prune: keep newest $KEEP dated files, delete only older dated files
mapfile -t all < <(ls "$STATE"/baselines/packages-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].txt 2>/dev/null | sort)
del=$(( ${#all[@]} - KEEP ))
if [ "$del" -gt 0 ]; then
  for f in "${all[@]:0:$del}"; do rm -f -- "$f"; done
  log "pruned $del baseline(s) older than $(basename "${all[$del]}") (keeping newest $KEEP)"
fi

[ -n "$report" ] && echo "$report"
exit "$rc"
