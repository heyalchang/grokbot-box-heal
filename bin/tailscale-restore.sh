#!/usr/bin/env bash
# tailscale-restore.sh: idempotent self-heal for Tailscale on this box.
# Safe to run often. Never logs in fresh, never prints keys/state contents.
# Keeps a box-owned copy of the root-only state dir in $TS_HOME/state-backup (refreshed only when
# verified Running on the wanted tailnet and contents changed); restores it if the state file goes missing.
# Settings come from $RESTORE_CONFIG (default $BOX_WORKSPACE/restore/config.env): WANT_HOST, WANT_TAILNET (required),
# WANT_SUFFIX, WANT_IP (optional; empty = not checked), TAILSCALE_SSH (on|off, default on).
# Usage: tailscale-restore.sh [--first-run]
#   --first-run  (human use, one time) allow starting tailscaled with an EMPTY state dir, so the owner can then sign in with
#                `sudo tailscale up ...` themselves. Still never logs in; ends with exit 2 NEEDS LOGIN until someone signs in.
# Exit codes: 0 healthy/restored | 2 NEEDS LOGIN (or config missing) | 3 no sudo | 4 binaries unavailable
#             5 tailscaled failed to start | 6 still unhealthy | 75 another run holds the lock
set -uo pipefail
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

FIRST_RUN=0 FR_HINT=""
case "${1:-}" in
  --first-run) FIRST_RUN=1; FR_HINT=" (first run: tailscaled is up; now sign in yourself with sudo tailscale up, see README)" ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown arg: $1" >&2; exit 64 ;;
esac

WS=${BOX_WORKSPACE:-/workspace}
CONF=${RESTORE_CONFIG:-$WS/restore/config.env}
WANT_HOST="" WANT_TAILNET="" WANT_SUFFIX="" WANT_IP="" TAILSCALE_SSH="on"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
# Tailscale SSH: anything but "off" means on. SSH_FLAG goes to tailscale up/set; WANT_RUNSSH is the expected RunSSH pref.
if [ "$TAILSCALE_SSH" = off ]; then SSH_FLAG=--ssh=false WANT_RUNSSH=false; else SSH_FLAG=--ssh WANT_RUNSSH=true; fi

TS_HOME=${TS_HOME:-$WS/tailscale}
BACKUP_BIN=$TS_HOME/bin
STATE_DIR=$TS_HOME/state
STATE_FILE=$STATE_DIR/tailscaled.state
INSTALL_DIR=/usr/local/bin
SOCK=/var/run/tailscale/tailscaled.sock
LOG=$TS_HOME/restore.log
LOCK=$TS_HOME/.restore.lock
BACKUP_DIR=$TS_HOME/state-backup          # box-owned copy of the root-only state dir (0700 dir, 0600 files)
BACKUP_META=$BACKUP_DIR/.meta             # "source=Running ..." line; written only from a verified-healthy node
BACKUP_ITEMS=(tailscaled.state ssh certs) # what in --statedir matters (missing ones are skipped)
DAEMON_LOG=$TS_HOME/logs/tailscaled-$(date +%F).log
UP_FLAGS=("$SSH_FLAG" "--hostname=$WANT_HOST" --accept-dns=false --accept-routes=false)

TS="$INSTALL_DIR/tailscale"
TSD="$INSTALL_DIR/tailscaled"
ACTIONS=0
CALLER="${TS_RESTORE_CALLER:-manual}"

log() { printf '%s [pid %s %s] %s\n' "$(date '+%F %T %Z')" "$$" "$CALLER" "$*" >>"$LOG"; [ -t 1 ] && printf '%s\n' "$*"; return 0; }
die() { local rc=$1; shift; log "FAIL($rc): $*"; exit "$rc"; }

mkdir -p "$TS_HOME" "$(dirname "$DAEMON_LOG")"
if [ -z "$WANT_HOST" ] || [ -z "$WANT_TAILNET" ]; then
  die 2 "NEEDS HUMAN: WANT_HOST and WANT_TAILNET must be set in $CONF (see config.env.example)"
fi
exec 9>>"$LOCK"
if ! flock -w 20 9; then log "another restore run holds the lock; skipping"; exit 75; fi

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo -n); fi
"${SUDO[@]}" true 2>/dev/null || die 3 "passwordless sudo unavailable"

tsc() { "${SUDO[@]}" "$TS" --socket="$SOCK" "$@"; }
st_json() { tsc status --json 2>/dev/null; }
backend() { st_json | jq -r '.BackendState // "unknown"' 2>/dev/null || echo unknown; }
tailnet() { st_json | jq -r '.CurrentTailnet.Name // ""' 2>/dev/null; }
summary() {
  st_json | jq -r '[.BackendState, (.CurrentTailnet.Name // "-"), (.CurrentTailnet.MagicDNSSuffix // "-"), (.Self.HostName // "-"), ((.Self.TailscaleIPs // [])[0] // "-")] | join(" ")' 2>/dev/null
}
run_ssh() { tsc debug prefs 2>/dev/null | jq -r '.RunSSH' 2>/dev/null; }
wait_backend() { # wait_backend <seconds> : wait until state is not NoState/Starting/unknown
  local i s
  for ((i = 0; i < $1; i++)); do
    s=$(backend)
    case "$s" in Running|NeedsLogin|NeedsMachineAuth|Stopped) echo "$s"; return 0 ;; esac
    sleep 1
  done
  backend
}
bin_ok() { [ -x "$1" ] && "$1" version >/dev/null 2>&1; }

# ---- state backup helpers (never print contents; only checksums are compared, in memory) ----
# sums_of <dir> <cmd-prefix...>: sorted "sha256  ./path" lines for BACKUP_ITEMS under <dir>
sums_of() {
  local d=$1; shift
  "$@" sh -c 'cd "$1" 2>/dev/null || exit 0; shift
    for i in "$@"; do [ -e "$i" ] && find "$i" -type f -print0; done | sort -z | xargs -0 -r sha256sum' \
    sh "$d" "${BACKUP_ITEMS[@]}" 2>/dev/null
}
live_sums()   { sums_of "$STATE_DIR" "${SUDO[@]}"; }
backup_sums() { sums_of "$BACKUP_DIR"; }
backup_ok()   { [ -s "$BACKUP_DIR/tailscaled.state" ] && grep -q '^source=Running ' "$BACKUP_META" 2>/dev/null; }
backup_when() { sed -n 's/.* saved=\([^ ]*\).*/\1/p' "$BACKUP_META" 2>/dev/null | head -1; }

# refresh_backup: copy live state -> $BACKUP_DIR atomically, only if contents changed. Never fatal.
refresh_backup() {
  local live old tmp owner
  live=$(live_sums)
  [ -n "$live" ] && printf '%s\n' "$live" | grep -q '  tailscaled\.state$' || { log "WARN: state-backup not refreshed (could not read live state)"; return 0; }
  old=$(backup_sums)
  if [ "$live" = "$old" ] && backup_ok; then return 0; fi
  owner=$(stat -c %U:%G "$TS_HOME")
  tmp=$(umask 077; mktemp -d "$TS_HOME/.state-backup.tmp.XXXXXX") || { log "WARN: state-backup: mktemp failed"; return 0; }
  (
    set -e; umask 077
    "${SUDO[@]}" tar -C "$STATE_DIR" -cf - --ignore-failed-read "${BACKUP_ITEMS[@]}" 2>/dev/null | tar -C "$tmp" -xf - --no-same-owner --no-same-permissions
    [ "$(id -u)" -eq 0 ] && chown -R "$owner" "$tmp"
    find "$tmp" -type d -exec chmod 0700 {} +
    find "$tmp" -type f -exec chmod 0600 {} +
    [ "$(sums_of "$tmp")" = "$live" ]   # copy must match what we checksummed (no mid-write race)
    printf 'source=Running tailnet=%s host=%s ip=%s saved=%s\n' "$WANT_TAILNET" "$host" "$ip" "$(date '+%FT%T%z')" >"$tmp/.meta"
    chmod 0600 "$tmp/.meta"
  ) || { rm -rf "$tmp"; log "WARN: state-backup refresh failed (copy/verify); previous backup kept"; return 0; }
  if [ -d "$BACKUP_DIR" ] && mv --exchange -T "$tmp" "$BACKUP_DIR" 2>/dev/null; then
    rm -rf "$tmp"
  else
    rm -rf "$BACKUP_DIR.prev"; [ -d "$BACKUP_DIR" ] && mv -T "$BACKUP_DIR" "$BACKUP_DIR.prev"
    mv -T "$tmp" "$BACKUP_DIR" || { log "WARN: state-backup: final mv failed"; return 0; }
    rm -rf "$BACKUP_DIR.prev"
  fi
  chmod 0700 "$BACKUP_DIR"
  log "backup: refreshed $BACKUP_DIR ($(printf '%s\n' "$live" | wc -l) files, contents changed)"
}

# restore_backup: copy $BACKUP_DIR -> $STATE_DIR as root (dir 0700, files 0600). Returns non-zero on failure.
restore_backup() {
  local items=() i
  for i in "${BACKUP_ITEMS[@]}"; do [ -e "$BACKUP_DIR/$i" ] && items+=("$i"); done
  tar -C "$BACKUP_DIR" -cf - "${items[@]}" 2>/dev/null | "${SUDO[@]}" sh -c '
    set -e; umask 077; sd=$1
    mkdir -p "$sd"; chown root:root "$sd"; chmod 0700 "$sd"
    t=$(mktemp -d "$sd/.restore.XXXXXX")
    trap "cd /; rm -rf -- \"$t\"" EXIT
    tar -C "$t" -xf - --no-same-owner --no-same-permissions
    chown -R root:root "$t"; find "$t" -type d -exec chmod 0700 {} +; find "$t" -type f -exec chmod 0600 {} +
    cd "$t"
    find . -type f ! -path ./tailscaled.state | while IFS= read -r f; do
      mkdir -p "$sd/$(dirname "$f")"; chmod 0700 "$sd/$(dirname "$f")"; mv -f "$f" "$sd/$f"; done
    mv -f tailscaled.state "$sd/tailscaled.state"   # main state file last
' sh "$STATE_DIR" 2>/dev/null || return 1
  [ "$(live_sums)" = "$(backup_sums)" ]
}

# warn_if_backup: conservative hint when the live node is logged out but a Running-node backup differs. No overwrite.
warn_if_backup() {
  backup_ok || return 0
  [ "$(live_sums)" = "$(backup_sums)" ] && return 0
  log "WARN: live state is logged out but $BACKUP_DIR (from a Running node, saved $(backup_when)) differs; NOT auto-restoring. If this is an unwanted fresh node: stop tailscaled, move $STATE_FILE aside, re-run this script"
}

# ---- 1. binaries ---------------------------------------------------------
if ! bin_ok "$TS" || ! [ -x "$TSD" ] || ! "$TSD" --version >/dev/null 2>&1; then
  if bin_ok "$BACKUP_BIN/tailscale" && "$BACKUP_BIN/tailscaled" --version >/dev/null 2>&1; then
    "${SUDO[@]}" install -m 0755 "$BACKUP_BIN/tailscale" "$BACKUP_BIN/tailscaled" "$INSTALL_DIR/" \
      || die 4 "install from $BACKUP_BIN failed"
    log "ACTION: installed tailscale+tailscaled $("$TS" version | head -1) into $INSTALL_DIR from backup (offline)"
  else
    log "backup binaries missing/broken in $BACKUP_BIN; falling back to official static tarball"
    tmp=$(mktemp -d) || die 4 "mktemp failed"
    (
      set -e; cd "$tmp"
      case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; armv7l) ARCH=arm ;; i?86) ARCH=386 ;; *) exit 1 ;; esac
      VER=$(curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json" | jq -r .TarballsVersion)
      curl -fsSL -o "ts_${VER}.tgz" "https://pkgs.tailscale.com/stable/tailscale_${VER}_${ARCH}.tgz"
      echo "$(curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${VER}_${ARCH}.tgz.sha256")  ts_${VER}.tgz" | sha256sum -c - >/dev/null
      tar xzf "ts_${VER}.tgz"
      mkdir -p "$BACKUP_BIN"
      install -m 0755 "tailscale_${VER}_${ARCH}/tailscale" "tailscale_${VER}_${ARCH}/tailscaled" "$BACKUP_BIN/"
    ) || { rm -rf "$tmp"; die 4 "tarball download/verify failed"; }
    rm -rf "$tmp"
    "${SUDO[@]}" install -m 0755 "$BACKUP_BIN/tailscale" "$BACKUP_BIN/tailscaled" "$INSTALL_DIR/" \
      || die 4 "install after download failed"
    log "ACTION: downloaded+verified $("$TS" version | head -1), saved to $BACKUP_BIN, installed into $INSTALL_DIR"
  fi
  ACTIONS=$((ACTIONS + 1))
fi

# ---- 2. dirs + tun -------------------------------------------------------
if [ ! -d /var/run/tailscale ]; then "${SUDO[@]}" mkdir -p /var/run/tailscale && log "ACTION: created /var/run/tailscale"; ACTIONS=$((ACTIONS + 1)); fi
if [ ! -c /dev/net/tun ]; then
  "${SUDO[@]}" mkdir -p /dev/net && "${SUDO[@]}" mknod /dev/net/tun c 10 200 && "${SUDO[@]}" chmod 0666 /dev/net/tun \
    && log "ACTION: created /dev/net/tun" || log "WARN: could not create /dev/net/tun"
  ACTIONS=$((ACTIONS + 1))
fi
if ! "${SUDO[@]}" test -s "$STATE_FILE"; then
  if [ "$FIRST_RUN" = 1 ] && ! backup_ok; then
    "${SUDO[@]}" mkdir -p "$STATE_DIR" && "${SUDO[@]}" chmod 0700 "$STATE_DIR"
    log "first run: no saved state yet; starting tailscaled with an empty state dir (no login attempted)"
  elif ! backup_ok; then
    die 2 "NEEDS LOGIN: saved state $STATE_FILE missing/empty and no usable $BACKUP_DIR; refusing to start a fresh node (no login attempted)"
  elif pgrep -x tailscaled >/dev/null 2>&1; then
    die 2 "NEEDS LOGIN: saved state $STATE_FILE missing/empty while tailscaled is already running; backup exists in $BACKUP_DIR (saved $(backup_when)) but not restoring under a live daemon. Stop tailscaled and re-run"
  elif restore_backup; then
    ACTIONS=$((ACTIONS + 1)); log "ACTION: restored tailscaled state from state-backup (saved $(backup_when))"
  else
    die 2 "NEEDS LOGIN: saved state $STATE_FILE missing/empty and restore from $BACKUP_DIR failed (no login attempted)"
  fi
fi

# ---- 3. daemon -----------------------------------------------------------
start_daemon() {
  "${SUDO[@]}" sh -c 'cd / && nohup setsid "$1" --state="$2" --statedir="$3" --socket="$4" >>"$5" 2>&1 </dev/null &' \
    sh "$TSD" "$STATE_FILE" "$STATE_DIR" "$SOCK" "$DAEMON_LOG"
}
if pgrep -x tailscaled >/dev/null 2>&1; then
  if [ "$(wait_backend 15)" = unknown ]; then
    log "tailscaled running but socket unresponsive after 15s; restarting it"
    "${SUDO[@]}" pkill -x tailscaled; sleep 3; "${SUDO[@]}" pkill -9 -x tailscaled 2>/dev/null
    start_daemon; ACTIONS=$((ACTIONS + 1)); log "ACTION: restarted tailscaled (log $DAEMON_LOG)"
  fi
else
  start_daemon; ACTIONS=$((ACTIONS + 1))
  log "ACTION: started tailscaled --state=$STATE_FILE --statedir=$STATE_DIR --socket=$SOCK (log $DAEMON_LOG)"
fi
S=$(wait_backend 30)
[ "$S" = unknown ] && die 5 "tailscaled did not come up (see $DAEMON_LOG)"

# ---- 4. profile / backend ------------------------------------------------
if [ "$(tailnet)" != "$WANT_TAILNET" ]; then
  pid=$(tsc switch --list 2>/dev/null | awk -v t="$WANT_TAILNET" 'NR>1 && ($2==t || $3==t || $3==t"*") {print $1; exit}')
  [ -n "$pid" ] || { warn_if_backup; die 2 "NEEDS LOGIN: no saved profile for $WANT_TAILNET (current tailnet '$(tailnet)'); not logging in$FR_HINT"; }
  log "active tailnet is '$(tailnet)' (state $S); switching to profile $pid ($WANT_TAILNET)"
  tsc switch "$pid" >/dev/null 2>&1 || die 6 "tailscale switch $pid failed"
  ACTIONS=$((ACTIONS + 1)); log "ACTION: switched to profile $pid"
  sleep 2; S=$(wait_backend 30)
fi
case "$S" in
  NeedsLogin|NeedsMachineAuth) warn_if_backup; die 2 "NEEDS LOGIN: BackendState=$S on $(tailnet); not opening a login$FR_HINT" ;;
esac
if [ "$S" != Running ]; then
  log "BackendState=$S; running tailscale up ${UP_FLAGS[*]} (non-interactive, 30s timeout)"
  out=$(timeout 45 "${SUDO[@]}" "$TS" --socket="$SOCK" up "${UP_FLAGS[@]}" --timeout=30s 2>&1); rc=$?
  if printf '%s' "$out" | grep -qiE 'to authenticate|https?://'; then
    warn_if_backup; die 2 "NEEDS LOGIN: tailscale up wanted an interactive login (URL suppressed); not opening it"
  fi
  [ $rc -eq 0 ] || log "tailscale up rc=$rc: $(printf '%s' "$out" | grep -viE 'https?://' | tr '\n' ' ' | cut -c1-300)"
  ACTIONS=$((ACTIONS + 1)); S=$(wait_backend 30)
fi
case "$S" in NeedsLogin|NeedsMachineAuth) warn_if_backup; die 2 "NEEDS LOGIN: BackendState=$S after up$FR_HINT" ;; esac
[ "$S" = Running ] || die 6 "BackendState=$S after recovery attempts ($(summary))"

ssh_is() { [ "$(run_ssh)" = true ] && echo true || echo false; }   # RunSSH as true/false (unreadable = false)
if [ "$(ssh_is)" != "$WANT_RUNSSH" ] || [ "$(st_json | jq -r '.Self.HostName')" != "$WANT_HOST" ]; then
  tsc set "$SSH_FLAG" --hostname="$WANT_HOST" >/dev/null 2>&1 && log "ACTION: tailscale set $SSH_FLAG --hostname=$WANT_HOST" || log "WARN: tailscale set $SSH_FLAG failed"
  ACTIONS=$((ACTIONS + 1))
fi

# ---- 5. verify -----------------------------------------------------------
SUM=$(summary); SSH=$(run_ssh)
read -r _ tn sfx host ip <<<"$SUM"
[ "$tn" = "$WANT_TAILNET" ] || die 6 "wrong tailnet after recovery: $SUM"
[ -z "$WANT_SUFFIX" ] || [ "$sfx" = "$WANT_SUFFIX" ] || die 6 "wrong MagicDNS suffix after recovery: $SUM (want $WANT_SUFFIX)"
[ -z "$WANT_IP" ] || [ "$ip" = "$WANT_IP" ] || log "WARN: IP is $ip, expected $WANT_IP (node may have been re-registered)"
[ "$host" = "$WANT_HOST" ] || log "WARN: hostname is $host, expected $WANT_HOST"
# verified Running on $WANT_TAILNET: keep the box-owned state backup current (no-op unless contents changed)
[ "$(backend)" = Running ] && [ "$(tailnet)" = "$WANT_TAILNET" ] && refresh_backup
if [ "$ACTIONS" -eq 0 ]; then
  log "healthy (no action): $SUM ssh=$SSH"
else
  log "RESTORED after $ACTIONS action(s): $SUM ssh=$SSH"
fi
exit 0
