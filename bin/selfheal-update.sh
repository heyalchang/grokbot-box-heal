#!/usr/bin/env bash
# selfheal-update.sh: on-demand update helper for this kit from its git clone (state/kit-source).
# Never runs on a schedule by itself; intended to be run by the box owner or an agent when inspecting/applying updates.
# Usage: selfheal-update.sh [--caller NAME] [--apply]
#   UPDATE_MODE (config.env): off  = (default) do nothing unless --apply is given
#                             ask  = announce a new version once ("vNEW available: <changelog>")
#                             auto = fast-forward, re-install, re-check, roll back on failure
#   --apply        update now, whatever UPDATE_MODE says
# Exit: 0  nothing to do (up to date, off, already announced, or busy)
#       10 updated (one line: "updated vOLD -> vNEW: <changelog>")
#       11 new version available, ask mode (announced once per version)
#       20 needs a human (clone has uncommitted edits or diverged, not on main, fetch failed, kit-source unknown)
#       30 update failed and was rolled back ("update to vX failed, rolled back to vY")
# Env: BOX_WORKSPACE (default /workspace); BASHRC is passed through to install.sh.
set -uo pipefail

main() {
  export HOME=${HOME:-/home/box}
  export BOX_WORKSPACE=${BOX_WORKSPACE:-/workspace}
  export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
  local WS=$BOX_WORKSPACE ROOT=$BOX_WORKSPACE/restore STATE=$BOX_WORKSPACE/restore/state
  local LOG=$ROOT/restore.log CALLER=manual APPLY=0 MODE BRANCH=main
  while [ $# -gt 0 ]; do
    case "$1" in
      --caller) CALLER=${2:-}; shift ;;
      --apply) APPLY=1 ;;
      --force-check) ;;   # accepted for backwards compatibility; rate-limit stamp was removed
      -h|--help) sed -n '2,14p' "$0"; return 0 ;;
      *) echo "unknown arg: $1" >&2; return 64 ;;
    esac
    shift
  done
  log() { printf '%s [selfheal-update pid %s %s] %s\n' "$(date '+%F %T %Z')" "$$" "$CALLER" "$*" >>"$LOG"; }
  say() { log "$*"; printf '%s\n' "$*"; }
  quiet() { sed -E 's#https?://[^ ]+#<url>#g' | while IFS= read -r l; do [ -n "${l// }" ] && log "  $l"; done; }   # output -> log only

  # shellcheck disable=SC1091
  MODE=$( [ -r "$ROOT/config.env" ] && . "$ROOT/config.env" >/dev/null 2>&1; echo "${UPDATE_MODE:-off}")
  case $MODE in auto|ask|off) ;; *) log "unknown UPDATE_MODE=$MODE; treating as off"; MODE=off ;; esac
  [ "$MODE" = off ] && [ "$APPLY" = 0 ] && return 0
  mkdir -p "$STATE"

  exec 8>>"$STATE/.selfheal-update.lock"
  flock -n 8 || { log "another update run holds the lock; skipping"; return 0; }

  local SRC IV="" IC="" rc=0
  SRC=$(cat "$STATE/kit-source" 2>/dev/null)
  [ -r "$STATE/kit-version" ] && read -r IV IC _ <"$STATE/kit-version"
  if [ -z "$SRC" ] || [ -z "${IC:-}" ] || ! git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    say "update check: kit clone or installed version unknown; re-run install.sh from the clone"; return 20
  fi
  timeout 120 git -C "$SRC" fetch --quiet origin "$BRANCH" 2>&1 | quiet; rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ]; then
    say "update check: git fetch failed in $SRC"; return 20
  fi
  local NEW NV LINES
  NEW=$(git -C "$SRC" rev-parse "origin/$BRANCH") || { say "update check: no origin/$BRANCH in $SRC"; return 20; }
  if [ "$NEW" = "$IC" ]; then log "up to date (v$IV ${IC:0:12})"; return 0; fi
  NV=$(git -C "$SRC" show "$NEW:VERSION" 2>/dev/null | tr -d ' \t\r\n'); NV=${NV:-unknown}
  LINES=$(changes "$SRC" "$NEW" "$IV")

  if [ "$APPLY" = 0 ] && [ "$MODE" = ask ]; then
    if [ "$(cat "$STATE/update-last-announced" 2>/dev/null)" = "$NV" ]; then log "v$NV available (already announced)"; return 0; fi
    echo "$NV" >"$STATE/update-last-announced"
    say "v$NV available: $LINES"; return 11
  fi

  # auto or --apply: fast-forward only, never touch a clone with local work
  local head br OLD
  br=$(git -C "$SRC" symbolic-ref --short -q HEAD)
  [ "$br" = "$BRANCH" ] || { say "update to v$NV needs a human: clone $SRC is not on $BRANCH"; return 20; }
  [ -z "$(git -C "$SRC" status --porcelain)" ] || { say "update to v$NV needs a human: clone $SRC has uncommitted edits"; return 20; }
  head=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" merge-base --is-ancestor "$head" "$NEW" || { say "update to v$NV needs a human: clone $SRC has diverged from origin/$BRANCH"; return 20; }
  OLD=$head   # roll back to what is installed if the clone still has it in its history, else to the clone's HEAD
  if git -C "$SRC" cat-file -e "$IC^{commit}" 2>/dev/null && git -C "$SRC" merge-base --is-ancestor "$IC" "$head"; then OLD=$IC; fi

  log "updating v$IV (${OLD:0:12}) -> v$NV (${NEW:0:12}) in $SRC"
  local hookarg=""
  grep -qxF '# >>> box auto-restore >>>' "${BASHRC:-$HOME/.bashrc}" 2>/dev/null || hookarg=--no-hook
  git -C "$SRC" merge --ff-only -q "$NEW" 2>&1 | quiet
  if [ "${PIPESTATUS[0]}" != 0 ]; then say "update to v$NV needs a human: fast-forward failed in $SRC"; return 20; fi
  (cd "$SRC" && WORKSPACE=$WS ./install.sh ${hookarg:+"$hookarg"} </dev/null) 2>&1 | quiet; rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ]; then
    log "install.sh of v$NV failed (exit $rc)"; rc=30
  else
    "$WS/bin/restore-all.sh" --caller update --no-jobs </dev/null >/dev/null 2>&1; rc=$?   # it logs its own summary lines
    log "restore-all after update: exit $rc"
  fi
  if [ "$rc" = 30 ]; then
    log "rolling back to ${OLD:0:12}"
    git -C "$SRC" reset --hard -q "$OLD" 2>&1 | quiet
    # files the new version added are not in the old one; remove the installed copies so they don't linger
    git -C "$SRC" diff --name-only --diff-filter=A "$OLD" "$NEW" -- bin items jobs | while IFS= read -r f; do
      case $f in bin/*) rm -f "$WS/$f" ;; items/*|jobs/*) rm -f "$ROOT/$f"; rmdir "$(dirname "$ROOT/$f")" 2>/dev/null ;; esac
    done
    local OV; OV=$(tr -d ' \t\r\n' <"$SRC/VERSION" 2>/dev/null); OV=${OV:-$IV}
    (cd "$SRC" && WORKSPACE=$WS ./install.sh ${hookarg:+"$hookarg"} </dev/null) 2>&1 | quiet; rc=${PIPESTATUS[0]}
    if [ "$rc" = 0 ]; then
      say "update to v$NV failed, rolled back to v$OV"
    else
      say "update to v$NV failed, and re-installing v$OV failed too; see $LOG"
    fi
    return 30
  fi
  say "updated v$IV -> v$NV: $LINES"; return 10
}

# changes <clone> <commit> <old version>: changelog lines newer than <old version>, newest first, joined with "; "
changes() {
  local out
  out=$(git -C "$1" show "$2:CHANGELOG.md" 2>/dev/null | sed -nE 's/^- ([0-9][0-9A-Za-z.-]*): (.*)$/\1\t\2/p' \
    | while IFS=$'\t' read -r v t; do
        [ "$v" != "$3" ] && [ "$(printf '%s\n%s\n' "$v" "$3" | sort -V | tail -n 1)" = "$v" ] && printf 'v%s %s\n' "$v" "$t"
      done)
  [ -n "$out" ] || { echo "(no changelog entry)"; return; }
  [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && out=${out#v* }   # one version: just its text
  printf '%s\n' "$out" | sed -E 's#https?://[^ ]+#<url>#g' | paste -sd ';' - | sed 's/;/; /g'
}

main "$@"; exit $?   # whole file is parsed before anything runs, so install.sh may replace this script mid-run
