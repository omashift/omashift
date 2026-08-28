# Runtime file locations for the shell side, matching lib/runtime.lua exactly.
#
# Sourced, not run. Two copies of "where does the state file live" would drift,
# and the engine and the launcher disagreeing about that path is a game that
# runs with an overlay showing nothing.
#
# See lib/runtime.lua for why none of this is in /tmp any more. The short
# version: $XDG_RUNTIME_DIR is 0700 and per user, so a predictable name inside
# it is not reachable by anybody who could abuse it.

# The private directory for this session, created if needed and verified after.
#
# Verified AFTER creating, because mkdir on an existing path succeeds without
# touching its mode or owner. A pre-planted directory is the whole attack, so
# "it exists now" is not the question worth asking.
omashift_runtime_dir() {
  local want
  if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
    want="$XDG_RUNTIME_DIR/omashift"
  else
    # No login session: ssh, cron, a bare shell. Still per user, still 0700.
    want="/tmp/omashift-$(id -u)"
  fi

  mkdir -p -m 700 -- "$want" 2>/dev/null

  # -d a directory, ! -L not a symlink to one, -O owned by us.
  [[ -d $want && ! -L $want && -O $want ]] || return 1
  [[ $(stat -c %a -- "$want" 2>/dev/null) == 700 ]] || return 1

  printf '%s\n' "$want"
}

# Resolve one runtime file: the override if there is one, else ours.
#
# The override may point anywhere, because the suite drives every screen
# through it. What it cannot do is skip the checks that follow it around:
# omashift_safe_read still refuses a symlink wherever it was pointed.
omashift_runtime_path() {
  local env_name=$1 filename=$2 override dir
  override=${!env_name:-}
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  dir=$(omashift_runtime_dir) || return 1
  printf '%s/%s\n' "$dir" "$filename"
}

# Read a runtime file, or refuse and say nothing.
#
# Bash says exactly what the review asked for: a regular file, not a symlink,
# owned by us, and no bigger than we are willing to parse. A state document is
# a screen; anything approaching this cap is not one.
omashift_safe_read() {
  local p=$1 max=${2:-262144} sz
  [[ -f $p && ! -L $p && -O $p ]] || return 1
  sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0)
  (( sz > 0 && sz <= max )) || return 1
  head -c "$max" -- "$p"
}
