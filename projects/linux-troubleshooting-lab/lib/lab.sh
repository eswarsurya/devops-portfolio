# Shared helpers for every scenario. Sourced, not executed.
# shellcheck shell=bash

# Where scenarios keep their runtime state (pid files, configs, loop images).
LAB_ROOT="${LAB_ROOT:-/tmp/linux-lab}"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_DIR

# STATE is per scenario. ARTIFACTS holds anything a reviewer may want to download
# (packet captures, logs). Both are set by run-scenario.sh; the defaults let you
# run a single script by hand.
SCENARIO="${SCENARIO:-$(basename "$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)")}"
STATE="${STATE:-$LAB_ROOT/state/$SCENARIO}"
ARTIFACTS="${ARTIFACTS:-$LAB_ROOT/artifacts/$SCENARIO}"
mkdir -p "$STATE" "$ARTIFACTS"

# A diagnose script reports what it found with `finding key value`.
# run-scenario.sh compares these lines with what break.sh planted.
finding() {
  printf 'FINDING %s=%s\n' "$1" "$2"
}

# Print a heading so the evidence reads like an investigation.
step() {
  printf '\n### %s\n' "$*"
}

# Print the command, then run it. Output is shown as-is. A failing command
# does not stop the investigation (a failing curl is often the evidence).
show() {
  printf '$ %s\n' "$*"
  "$@" 2>&1 || printf '(exit code %s)\n' "$?"
}

# Same as show, for commands that need a shell (pipes).
show_sh() {
  printf '$ %s\n' "$1"
  bash -c "$1" 2>&1 || printf '(exit code %s)\n' "$?"
}

# break.sh records the planted cause here. diagnose.sh must never read it.
plant() {
  mkdir -p "$(dirname "$LAB_ANSWER")"
  printf '%s=%s\n' "$1" "$2" >> "$LAB_ANSWER"
}
LAB_ANSWER="${LAB_ANSWER:-$LAB_ROOT/answers/$SCENARIO.env}"

# wait_until <seconds> <command...>: retry every 0.2s until the command succeeds.
wait_until() {
  local limit=$(( $1 * 5 )) i=0
  shift
  until "$@" >/dev/null 2>&1; do
    i=$(( i + 1 ))
    if (( i >= limit )); then return 1; fi
    sleep 0.2
  done
}

# Start a long-running process in the background, fully detached from the
# caller's stdout so the runner does not hang, and record its pid.
# Usage: start_bg <name> <command...>
start_bg() {
  local name="$1"
  shift
  setsid "$@" >"$STATE/$name.log" 2>&1 < /dev/null &
  echo $! > "$STATE/$name.pid"
  disown   # no "Killed" job notices when we stop it later
}

# Kill a process started with start_bg (and its process group). Safe if gone.
stop_bg() {
  local pidfile="$STATE/$1.pid" pid
  [[ -f "$pidfile" ]] || return 0
  pid="$(cat "$pidfile")"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  rm -f "$pidfile"
}

# ---- network namespaces ----------------------------------------------------
# Two "hosts" joined by a veth pair:
#   <cli_ns> (veth <cli_if>, <cli_ip>/24)  <---->  <srv_ns> (veth <srv_if>, <srv_ip>/24)
netns_pair() {
  local cli_ns="$1" srv_ns="$2" cli_if="$3" srv_if="$4" cli_ip="$5" srv_ip="$6"
  ip netns add "$cli_ns"
  ip netns add "$srv_ns"
  ip link add "$cli_if" type veth peer name "$srv_if"
  ip link set "$cli_if" netns "$cli_ns"
  ip link set "$srv_if" netns "$srv_ns"
  ip -n "$cli_ns" addr add "$cli_ip/24" dev "$cli_if"
  ip -n "$srv_ns" addr add "$srv_ip/24" dev "$srv_if"
  for ns in "$cli_ns" "$srv_ns"; do
    ip -n "$ns" link set lo up
  done
  ip -n "$cli_ns" link set "$cli_if" up
  ip -n "$srv_ns" link set "$srv_if" up
}

netns_del() {
  local ns
  for ns in "$@"; do
    if ip netns pids "$ns" >/dev/null 2>&1; then
      ip netns pids "$ns" 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true
      ip netns del "$ns" 2>/dev/null || true
    fi
  done
}

# Is something listening on a TCP port inside a namespace (or the root ns)?
port_open() {
  local ns="$1" port="$2"
  if [[ -n "$ns" ]]; then
    ip netns exec "$ns" ss -Hltn "sport = :$port" | grep -q .
  else
    ss -Hltn "sport = :$port" | grep -q .
  fi
}
