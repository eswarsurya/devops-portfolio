#!/usr/bin/env bash
# Offline tests for backup.sh / restore.sh using a fake aws CLI.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"
pass=0; failn=0

ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; failn=$((failn+1)); }

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/src/site" "$T/s3/test-bucket"
  cp "$HERE/fake-aws" "$T/bin/aws"; chmod +x "$T/bin/aws"
  echo "hello" > "$T/src/site/index.html"
  echo "body{}" > "$T/src/site/style.css"
  export PATH="$T/bin:$PATH" FAKE_S3_ROOT="$T/s3"
  export SOURCE_DIR="$T/src/site" BUCKET="test-bucket" PREFIX="host1" WORK_DIR="$T/work"
  unset DRY_RUN KEY
}
teardown() { rm -rf "$T"; }

# 1. happy path uploads archive + checksum
setup
if "$SCRIPTS/backup.sh" >/dev/null 2>&1 \
   && ls "$T/s3/test-bucket/host1/"site-*.tar.gz >/dev/null 2>&1 \
   && ls "$T/s3/test-bucket/host1/"site-*.tar.gz.sha256 >/dev/null 2>&1; then
  ok "backup uploads archive and checksum"
else bad "backup uploads archive and checksum"; fi
teardown

# 2. missing SOURCE_DIR exits 1
setup
SOURCE_DIR="$T/nope" "$SCRIPTS/backup.sh" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]]; then ok "missing source dir exits 1"; else bad "missing source dir exits 1 (got $rc)"; fi
teardown

# 3. missing BUCKET exits 1
setup
BUCKET="" "$SCRIPTS/backup.sh" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]]; then ok "missing bucket exits 1"; else bad "missing bucket exits 1 (got $rc)"; fi
teardown

# 4. dry run builds archive but uploads nothing
setup
DRY_RUN=true "$SCRIPTS/backup.sh" >/dev/null 2>&1
if ls "$T/work/"site-*.tar.gz >/dev/null 2>&1 && [[ -z "$(ls -A "$T/s3/test-bucket")" ]]; then
  ok "dry run skips upload"
else bad "dry run skips upload"; fi
teardown

# 5. local pruning keeps only KEEP_LOCAL archives
setup
for _ in 1 2 3 4; do KEEP_LOCAL=2 "$SCRIPTS/backup.sh" >/dev/null 2>&1; sleep 1; done
n="$(find "$T/work" -name "*.tar.gz" | wc -l)"
if [[ "$n" -eq 2 ]]; then ok "prunes to KEEP_LOCAL=2"; else bad "prunes to KEEP_LOCAL=2 (found $n)"; fi
teardown

# 6. restore round-trip: content matches and checksum verified
setup
"$SCRIPTS/backup.sh" >/dev/null 2>&1
if PREFIX=host1 DEST="$T/restore" "$SCRIPTS/restore.sh" >/dev/null 2>&1 \
   && diff -r "$T/src/site" "$T/restore/site" >/dev/null; then
  ok "restore round-trip matches source"
else bad "restore round-trip matches source"; fi
teardown

# 7. corrupted archive is rejected on restore
setup
"$SCRIPTS/backup.sh" >/dev/null 2>&1
f="$(ls "$T/s3/test-bucket/host1/"*.tar.gz)"
echo "tampered" >> "$f"
PREFIX=host1 DEST="$T/restore" "$SCRIPTS/restore.sh" >/dev/null 2>&1; rc=$?
if [[ $rc -ne 0 ]]; then ok "restore rejects corrupted archive"; else bad "restore rejects corrupted archive"; fi
teardown

echo "---- $pass passed, $failn failed"
[[ $failn -eq 0 ]]
