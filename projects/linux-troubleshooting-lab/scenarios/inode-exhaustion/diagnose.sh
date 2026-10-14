#!/usr/bin/env bash
# "Uploads fail with 'No space left on device', but df shows free space."
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lab.sh
source "$HERE/../../lib/lab.sh"

step "1. Reproduce the error"
err="$(touch /srv/linux-lab-data/app/uploads/new-upload 2>&1)"
echo "$ touch /srv/linux-lab-data/app/uploads/new-upload"
echo "$err"
write_error="$(sed -nE 's/.*: (No space left on device)$/\1/p' <<<"$err")"

step "2. Blocks look fine..."
show df -h -x tmpfs -x devtmpfs -x squashfs -x overlay

step "3. ...but which filesystem is out of inodes? (every file and directory needs one)"
show df -i -x tmpfs -x devtmpfs -x squashfs -x overlay
full="$(df --output=ipcent,target -x tmpfs -x devtmpfs -x squashfs -x overlay | awk '$1 == "100%" {print $2; exit}')"
use="$(df --output=ipcent "$full" | tail -1 | tr -d ' ')"
echo "Filesystem at 100% inode use: $full"
show_sh "stat -f -c 'inodes total=%c free=%d, blocks total=%b free=%f (block size %S)' $full"

step "4. Where are all the files? Count entries per directory"
show_sh "find $full -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -5"
top="$(find "$full" -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
show_sh "ls $top | head -3; ls $top | wc -l"
show_sh "du -sh $top"
echo "About a thousand empty files: almost no space used, but each one costs an inode."

finding mount "$full"
finding inode_use "$use"
finding top_dir "$top"
finding write_error "$write_error"
