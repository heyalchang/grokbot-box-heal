# lib.sh: shared by 20-package-drift check/restore and $BOX_WORKSPACE/bin/restore-baseline-snapshot.sh (sourced, not executed).
# shellcheck shell=bash disable=SC2034  # sourced library: its variables are used by the scripts that source it
# Baselines are daily read-only snapshots: $STATE_ROOT/baselines/packages-YYYY-MM-DD.txt (newest = the baseline).
# Test hooks (env): PKG_DRIFT_STATE=<alt state root>   PKG_DRIFT_BASELINE=<alt baseline file>
#                   PKG_DRIFT_DIR=<alt report/dedupe dir>   PKG_DRIFT_CURRENT=<file used instead of live dpkg-query>
# Nothing here writes a baseline.
STATE_ROOT=${PKG_DRIFT_STATE:-${BOX_WORKSPACE:-/workspace}/restore/state}
BASELINES_DIR=$STATE_ROOT/baselines
export LC_ALL=C
newest_baseline() { ls "$BASELINES_DIR"/packages-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].txt 2>/dev/null | sort | tail -n 1; }
BASELINE=${PKG_DRIFT_BASELINE:-$(newest_baseline)}
[ -n "$BASELINE" ] || BASELINE=$STATE_ROOT/packages-baseline.txt
DRIFT_DIR=${PKG_DRIFT_DIR:-$STATE_ROOT/drift}
ACK=$DRIFT_DIR/last-reported          # dedupe record: sha256 of last reported drift (incl. baseline name) + when + report

current_packages() { # live list (or the test override), name<TAB>version, sorted
  if [ -n "${PKG_DRIFT_CURRENT:-}" ]; then grep -v '^#' "$PKG_DRIFT_CURRENT" | sed '/^[[:space:]]*$/d' | sort -u
  else dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort -u; fi
}

# compute_drift [baseline_file] [current_file]: sets MISSING / EXTRA / CHANGED, NM NE NC, ALERT_HASH. Returns 1 on error.
compute_drift() {
  local bfile=${1:-$BASELINE} cur base
  [ -r "$bfile" ] || { DRIFT_ERR="baseline $bfile missing/unreadable"; return 1; }
  if [ -n "${2:-}" ]; then cur=$(grep -v '^#' "$2" | sed '/^[[:space:]]*$/d' | sort -u); else cur=$(current_packages); fi
  [ -n "$cur" ] || { DRIFT_ERR="package list empty (dpkg-query failed?)"; return 1; }
  base=$(grep -v '^#' "$bfile" | sed '/^[[:space:]]*$/d' | sort -u)
  MISSING=$(join -t $'\t' -v1 <(printf '%s\n' "$base") <(printf '%s\n' "$cur" | cut -f1))
  EXTRA=$(join -t $'\t' -v1 <(printf '%s\n' "$cur") <(printf '%s\n' "$base" | cut -f1))
  CHANGED=$(join -t $'\t' <(printf '%s\n' "$base") <(printf '%s\n' "$cur") | awk -F'\t' '$2 != $3 {print $1 "\t" $2 " -> " $3}')
  NM=$(printf '%s' "$MISSING" | grep -c . ); NE=$(printf '%s' "$EXTRA" | grep -c . ); NC=$(printf '%s' "$CHANGED" | grep -c . )
  # Only missing/extra alert; version changes are informational. The baseline's name is part of the hash, so a new
  # daily baseline never inherits an old acknowledgement.
  ALERT_HASH=$( { echo "baseline $(basename "$bfile")"; printf '%s\n' "$MISSING" | sed '/^$/d; s/^/MISSING\t/'; printf '%s\n' "$EXTRA" | sed '/^$/d; s/^/EXTRA\t/'; } | sha256sum | cut -d' ' -f1)
  return 0
}
names() { printf '%s\n' "$1" | cut -f1 | sed '/^$/d' | head -n "${2:-8}" | paste -sd, -; }
ack_field() { sed -n "s/^$1 //p" "$ACK" 2>/dev/null | head -1; }
write_diff_body() { # sections for a report (uses MISSING/EXTRA/CHANGED)
  echo; echo "## MISSING (in baseline, not in current): name<TAB>baseline-version"; printf '%s\n' "$MISSING" | sed '/^$/d'
  echo; echo "## EXTRA (in current, not in baseline): name<TAB>version"; printf '%s\n' "$EXTRA" | sed '/^$/d'
  echo; echo "## VERSION CHANGES (informational): name<TAB>baseline -> current"; printf '%s\n' "$CHANGED" | sed '/^$/d'
}
