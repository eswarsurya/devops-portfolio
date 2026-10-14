#!/usr/bin/env bash
# Capture a CPU profile from a node's pprof port and print the top functions.
#
#   scripts/profile.sh NODE SECONDS OUTFILE
#
# Needs Go on the machine for `go tool pprof`.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

node=${1:?usage: profile.sh NODE SECONDS OUTFILE}
seconds=${2:?usage: profile.sh NODE SECONDS OUTFILE}
out=${3:?usage: profile.sh NODE SECONDS OUTFILE}
port="606${node#kv}"

curl -sf --max-time $((seconds + 15)) -o "$out" \
  "http://127.0.0.1:$port/debug/pprof/profile?seconds=$seconds" ||
  fail "profile" "could not fetch a CPU profile from $node"
top=$(go tool pprof -top -cum -nodecount=25 "$out" 2> /dev/null | sed -n '1,32p')
{
  echo "### CPU profile of $node under load (${seconds}s, top functions by cumulative time)"
  echo
  echo '```'
  echo "$top"
  echo '```'
  echo
} | summary
notice "cpu profile $node" "$(echo "$top" | oneline)"
