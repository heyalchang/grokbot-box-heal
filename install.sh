#!/usr/bin/env bash
# install.sh: install or update the Grok Bot box restore kit from this clone. Idempotent; safe to re-run.
#  - copies bin/*.sh            -> $WORKSPACE/bin/
#  - copies items/*             -> $WORKSPACE/restore/items/ (overwrites kit files; never deletes your own items or DISABLED flags;
#                                  a kit item installed under an older number is moved to state/retired-*, DISABLED carried over)
#  - copies jobs/*              -> $WORKSPACE/restore/jobs/ (overwrites kit files; never deletes your own jobs or DISABLED flags)
#  - copies README.md           -> $WORKSPACE/restore/README.md
#  - creates $WORKSPACE/restore/config.env from config.env.example if it is missing (never overwrites it);
#    if it exists, appends any keys new in the example with their defaults (marked "added by update")
#  - records the kit version + commit in state/kit-version and this clone's path in state/kit-source
#  - installs/updates the ~/.bashrc hook between "# >>> box auto-restore >>>" and "# <<< box auto-restore <<<"
#    (replaces that block if present, otherwise prepends it; everything else in the file is left alone)
#  - takes the first package baseline if none exists (dpkg-query only)
# It never runs a login, never starts tailscaled, and never runs restore-all. Non-interactive.
#
# Usage: ./install.sh [--no-hook] [--no-baseline] [--hook-only]
#   --hook-only  only (re)install the ~/.bashrc hook block; touch nothing else (used by item 300-bashrc-hook)
# Env:   WORKSPACE (default /workspace)   BASHRC (default $HOME/.bashrc)   (override both to test in a scratch dir)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WS=${WORKSPACE:-/workspace}
BASHRC=${BASHRC:-${HOME:-/home/box}/.bashrc}
DO_HOOK=1 DO_BASELINE=1 HOOK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-hook) DO_HOOK=0 ;;
    --no-baseline) DO_BASELINE=0 ;;
    --hook-only) HOOK_ONLY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
  shift
done
BEGIN='# >>> box auto-restore >>>'
END='# <<< box auto-restore <<<'

[ -d "$HERE/bin" ] && [ -d "$HERE/items" ] && [ -d "$HERE/jobs" ] && [ -f "$HERE/hook/bashrc-block.sh" ] || { echo "run install.sh from a clone of the repo" >&2; exit 1; }
[[ "$WS" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "WORKSPACE must be an absolute path of [A-Za-z0-9._/-] characters: $WS" >&2; exit 1; }
WS=${WS%/}

for c in jq flock timeout sudo setsid; do command -v "$c" >/dev/null 2>&1 || echo "warning: '$c' not found; the kit needs it" >&2; done
[ -n "${EPOCHSECONDS:-}" ] || echo "warning: this bash has no EPOCHSECONDS; the hook's 15-min limit shells out to date +%s" >&2

if [ "$HOOK_ONLY" = 1 ]; then
  [ "$DO_HOOK" = 1 ] || { echo "--hook-only and --no-hook together make no sense" >&2; exit 64; }
  [ -d "$WS/restore/state" ] || { echo "no install under $WS yet; run install.sh without --hook-only first" >&2; exit 1; }
fi
if [ "$HOOK_ONLY" = 0 ]; then
echo "installing into $WS"
mkdir -p "$WS/bin" "$WS/restore/items" "$WS/restore/jobs" "$WS/restore/state"
for f in "$HERE"/bin/*.sh; do install -m 0755 "$f" "$WS/bin/"; done
for d in "$HERE"/items/*/; do
  name=$(basename "$d"); dest="$WS/restore/items/$name"
  mkdir -p "$dest"
  for f in "$d"* ; do [ -f "$f" ] && cp -p "$f" "$dest/"; done
  # a kit item that was installed under another number (kit < 1.5.0 used 05..35) is retired into state/, its DISABLED carried over
  [ "$name" = _template ] && continue
  for old in "$WS"/restore/items/[0-9]*-"${name#*-}"/; do
    old=${old%/}; [ -d "$old" ] && [ "$(basename "$old")" != "$name" ] || continue
    [ -e "$old/DISABLED" ] && touch "$dest/DISABLED"
    mv "$old" "$WS/restore/state/retired-$(basename "$old")-$(date +%F)" && echo "retired $old (now $name)"
  done
done
for d in "$HERE"/jobs/*/; do
  name=$(basename "$d"); dest="$WS/restore/jobs/$name"
  mkdir -p "$dest"
  for f in "$d"* ; do [ -f "$f" ] && cp -p "$f" "$dest/"; done
done
rm -f "$WS"/restore/state/agent-last-run.* "$WS/restore/agent-restore.log" \
      "$WS"/restore/hook.log* "$WS/tailscale/restore.log" \
      "$WS/restore/state/baseline-last-run" "$WS/restore/state/update-last-check" \
      "$WS/bin/selfheal-update.sh" "$WS/restore/state/.selfheal-update.lock" "$WS/restore/state/update-last-announced"
install -m 0644 "$HERE/README.md" "$WS/restore/README.md"
VER=$(tr -d ' \t\r\n' <"$HERE/VERSION" 2>/dev/null); VER=${VER:-unknown}
if [ -e "$WS/restore/config.env" ]; then
  echo "kept existing $WS/restore/config.env"
  # append keys that are new in the example (with the comment above them), never touching existing lines
  added=$(awk -v cfg="$WS/restore/config.env" -v ver="$VER" '
    BEGIN { while ((getline l < cfg) > 0) if (match(l, /^[A-Za-z_][A-Za-z0-9_]*=/)) have[substr(l, 1, RLENGTH - 1)] = 1 }
    /^#/ { doc = doc $0 "\n"; next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { k = substr($0, 1, index($0, "=") - 1)
      if (!(k in have)) printf "\n# %s: added by update to v%s with its default\n%s%s\n", k, ver, doc, $0 }
    { doc = "" }' "$HERE/config.env.example")
  if [ -n "$added" ]; then
    printf '%s\n' "$added" >>"$WS/restore/config.env"
    echo "added new setting(s) to $WS/restore/config.env: $(printf '%s\n' "$added" | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d = | tr '\n' ' ')"
  fi
else
  install -m 0644 "$HERE/config.env.example" "$WS/restore/config.env"
  echo "created $WS/restore/config.env from the example: edit it (WANT_HOST, WANT_TAILNET, optional WANT_SUFFIX/WANT_IP/GH_USER)"
fi
fi   # HOOK_ONLY

if [ "$DO_HOOK" = 1 ]; then
  block=$(sed "s#@WS@#$WS#g" "$HERE/hook/bashrc-block.sh")
  [ -e "$BASHRC" ] || : >"$BASHRC"
  nb=$(grep -cxF "$BEGIN" "$BASHRC" || true); ne=$(grep -cxF "$END" "$BASHRC" || true)
  tmp=$(mktemp)
  if [ "$nb" = 0 ] && [ "$ne" = 0 ]; then
    { printf '%s\n\n' "$block"; cat "$BASHRC"; } >"$tmp"
    action="added"
  elif [ "$nb" = 1 ] && [ "$ne" = 1 ] && [ "$(grep -nxF "$BEGIN" "$BASHRC" | cut -d: -f1)" -lt "$(grep -nxF "$END" "$BASHRC" | cut -d: -f1)" ]; then
    BLOCK=$block awk -v b="$BEGIN" -v e="$END" '
      $0 == b { print ENVIRON["BLOCK"]; skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }' "$BASHRC" >"$tmp"
    action="updated"
  else
    rm -f "$tmp"; echo "ERROR: $BASHRC has unbalanced auto-restore markers (begin=$nb end=$ne); fix by hand, nothing changed" >&2; exit 1
  fi
  if cmp -s "$tmp" "$BASHRC"; then
    echo "bashrc hook already current in $BASHRC"
  else
    cp -p "$BASHRC" "$WS/restore/state/bashrc.backup-$(date +%Y%m%dT%H%M%S)"
    cat "$tmp" >"$BASHRC"          # write in place: keeps the file's inode, mode, and any symlink
    echo "bashrc hook $action in $BASHRC (backup in $WS/restore/state/)"
  fi
  rm -f "$tmp"
fi
[ "$HOOK_ONLY" = 0 ] || exit 0

if [ "$DO_BASELINE" = 1 ] && command -v dpkg-query >/dev/null 2>&1 \
   && ! ls "$WS"/restore/state/baselines/packages-*.txt >/dev/null 2>&1; then
  if BOX_WORKSPACE=$WS "$WS/bin/restore-baseline-snapshot.sh" --caller install; then
    printf '%s 0 initial baseline\n' "$(date +%s)" >"$WS/restore/state/job-last-run.400-baseline-snapshot"
  else
    echo "warning: first package baseline failed; job 400-baseline-snapshot retries later" >&2
  fi
fi

commit=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)
echo "$VER $commit" >"$WS/restore/state/kit-version"
echo "$HERE" >"$WS/restore/state/kit-source"
echo "kit v$VER (${commit:0:12}) from $HERE"

cat <<NEXT

Done. Next steps (see README.md):
  1. Edit $WS/restore/config.env.
  2. One time, as a human: Tailscale sign-in (README "One-time human steps"); optionally the gh device login.
  3. Test: BOX_WORKSPACE=$WS $WS/bin/restore-all.sh; echo "exit=\$?"
NEXT
