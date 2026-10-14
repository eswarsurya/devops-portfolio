#!/usr/bin/env bash
# Run one scenario end to end:
#   break -> verify (must FAIL, the fault is real) -> diagnose (must find the
#   planted cause) -> fix -> verify (must PASS) -> cleanup (always).
#
# Usage: sudo ./run-scenario.sh <scenario>     (see scenarios/ for names)
#        sudo ./run-scenario.sh --list
set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--list" ]]; then
  ls "$LAB_DIR/scenarios"
  exit 0
fi

SCENARIO="${1:?usage: run-scenario.sh <scenario>}"
DIR="$LAB_DIR/scenarios/$SCENARIO"
[[ -d "$DIR" ]] || { echo "no such scenario: $SCENARIO" >&2; exit 2; }

if [[ $EUID -ne 0 ]]; then
  echo "This lab changes namespaces, mounts and cgroups. Run it with sudo." >&2
  exit 2
fi

# All lab traffic is local. A proxy from the environment would only get in the way.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY

export LAB_ROOT="${LAB_ROOT:-/tmp/linux-lab}"
export SCENARIO
export STATE="$LAB_ROOT/state/$SCENARIO"
export ARTIFACTS="$LAB_ROOT/artifacts/$SCENARIO"
export LAB_ANSWER="$LAB_ROOT/answers/$SCENARIO.env"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

rm -rf "$STATE" "$ARTIFACTS" "$LAB_ANSWER"
mkdir -p "$STATE" "$ARTIFACTS" "$(dirname "$LAB_ANSWER")"

# GitHub annotations cannot contain raw newlines; % must be escaped first.
annotate() {
  local title="$1" body="$2"
  body="${body//'%'/'%25'}"
  body="${body//$'\r'/}"
  body="${body//$'\n'/'%0A'}"
  echo "::error title=$SCENARIO: $title::$body"
}

fail() {
  local stage="$1" msg="$2" log="${3:-}"
  local detail="$msg"
  if [[ -n "$log" && -f "$log" ]]; then
    detail+=$'\n--- last lines of '"$(basename "$log")"$' ---\n'"$(tail -n 40 "$log")"
  fi
  annotate "$stage" "$detail"
  echo "FAILED at $stage: $msg" >&2
  {
    echo "### :x: \`$SCENARIO\` failed at **$stage**"
    echo
    echo "$msg"
  } >> "$SUMMARY"
  exit 1
}

cleanup() {
  timeout 120 bash "$DIR/cleanup.sh" > "$ARTIFACTS/cleanup.log" 2>&1 || echo "cleanup reported an error, see $ARTIFACTS/cleanup.log" >&2
}
trap cleanup EXIT

stage() {
  echo
  echo "==================== $SCENARIO: $1 ===================="
}

# Run <stage>.sh with a time limit. Output goes to a file (not a pipe), so a
# background process started by the script can never keep the runner waiting.
STAGE_TIMEOUT="${STAGE_TIMEOUT:-240}"
run_stage() {
  local rc=0
  timeout "$STAGE_TIMEOUT" bash "$DIR/$1.sh" > "$ARTIFACTS/$1.log" 2>&1 || rc=$?
  cat "$ARTIFACTS/$1.log"
  [[ $rc -eq 124 ]] && echo "$1.sh timed out after ${STAGE_TIMEOUT}s"
  return "$rc"
}

# Make sure nothing is left over from an earlier run.
timeout 120 bash "$DIR/cleanup.sh" > /dev/null 2>&1 || true

stage "break"
run_stage break || fail "break" "break.sh failed" "$ARTIFACTS/break.log"
[[ -s "$LAB_ANSWER" ]] || fail "break" "break.sh did not record what it planted"

stage "verify (expect the fault)"
if timeout "$STAGE_TIMEOUT" bash "$DIR/verify.sh" > "$ARTIFACTS/verify-broken.log" 2>&1; then
  cat "$ARTIFACTS/verify-broken.log"
  fail "verify-before-fix" "verify.sh passed right after break.sh, so the fault was not reproduced" "$ARTIFACTS/verify-broken.log"
fi
cat "$ARTIFACTS/verify-broken.log"
echo "OK: the service is broken, as planned."

stage "diagnose"
run_stage diagnose || fail "diagnose" "diagnose.sh exited with an error" "$ARTIFACTS/diagnose.log"

# Every key break.sh planted must be reported, with the same value, by diagnose.
mismatches=""
table=""
while IFS='=' read -r key want; do
  [[ -n "$key" ]] || continue
  got="$(grep -E "^FINDING ${key}=" "$ARTIFACTS/diagnose.log" | tail -n 1 | cut -d= -f2-)"
  if [[ "$got" == "$want" ]]; then
    table+="| \`$key\` | \`$want\` | \`$got\` | yes |"$'\n'
  else
    table+="| \`$key\` | \`$want\` | \`${got:-not found}\` | **no** |"$'\n'
    mismatches+="$key: planted '$want', diagnose found '${got:-nothing}'"$'\n'
  fi
done < "$LAB_ANSWER"

{
  echo "## \`$SCENARIO\`"
  echo
  echo "| Planted cause | Planted value | Found by diagnose.sh | Match |"
  echo "|---|---|---|---|"
  printf '%s' "$table"
  echo
  echo "<details><summary>Diagnose evidence (full output)</summary>"
  echo
  echo '```text'
  head -c 60000 "$ARTIFACTS/diagnose.log"
  echo '```'
  echo
  echo "</details>"
  echo
} >> "$SUMMARY"

if [[ -n "$mismatches" ]]; then
  fail "diagnose" "diagnose.sh did not identify the planted cause:"$'\n'"$mismatches" "$ARTIFACTS/diagnose.log"
fi
echo
echo "OK: diagnose found every planted cause."

stage "fix"
run_stage fix || fail "fix" "fix.sh failed" "$ARTIFACTS/fix.log"

stage "verify (expect healthy)"
ok=0
for attempt in 1 2 3; do
  if timeout "$STAGE_TIMEOUT" bash "$DIR/verify.sh" > "$ARTIFACTS/verify-fixed.log" 2>&1; then
    ok=1
    break
  fi
  echo "verify attempt $attempt failed, retrying"
  sleep 2
done
cat "$ARTIFACTS/verify-fixed.log"
[[ $ok -eq 1 ]] || fail "verify-after-fix" "verify.sh still fails after fix.sh" "$ARTIFACTS/verify-fixed.log"

echo
echo "PASS: $SCENARIO (fault reproduced, cause found, fix verified)"
echo ":white_check_mark: \`$SCENARIO\`: fault reproduced, cause found, fix verified." >> "$SUMMARY"
echo >> "$SUMMARY"
