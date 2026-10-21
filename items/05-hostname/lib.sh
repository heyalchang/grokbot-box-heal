# shared by check/restore of 05-hostname
CONF=${RESTORE_CONFIG:-${BOX_WORKSPACE:-/workspace}/restore/config.env}
WANT_OS_HOSTNAME=""
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
PROFILES=${HOME:-/home/box}/chrome-profile
hosts_ok() { grep -qE "^[0-9a-f.:]+[[:space:]]+([^#]*[[:space:]])?${WANT_OS_HOSTNAME//./\\.}([[:space:]]|\$)" /etc/hosts; }
# Chrome's SingletonLock is a symlink "<hostname>-<pid>". A second launch on a lock with another hostname refuses the profile
# ("in use by another computer"), so locks written under an old hostname are repointed to the current one (same pid).
stale_locks() {   # prints lock paths whose hostname part != current hostname
  local cur l t; cur=$(hostname)
  for l in "$PROFILES"/*/SingletonLock; do
    [ -L "$l" ] || continue
    t=$(readlink "$l"); [ "${t%-*}" = "$cur" ] || echo "$l"
  done
}
