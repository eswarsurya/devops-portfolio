# Disk full from a deleted file that is still open

**Reported symptom:** "The log disk was full, so I deleted the big log. `df` still says it is full. `du` says the files add up to almost nothing."

## What `break.sh` does

Creates a 64 MiB ext4 filesystem in a file, loop-mounts it at `/srv/linux-lab-logs`, and starts [logger.py](logger.py) (`audit-logger`), which writes a 40 MiB debug burst to `app.log` and keeps the file open. Then it does what people do under pressure: `rm app.log`.

## Investigate

1. **Compare `df` and `du`.** `df` asks the filesystem how many blocks are allocated. `du` walks the directory tree and adds up the files it can see. In CI: `df` used 41 MiB, `du` 1 MiB, a 40 MiB gap.
   A big gap means blocks belong to files no directory points to: deleted files that a process still has open. The kernel frees the blocks only when the last open file descriptor is closed.
2. **Find them.** `lsof -nP -a +L1 /srv/linux-lab-logs` lists open files with a link count below 1 on that filesystem (`-a` ANDs the two conditions). From CI:
   ```
   COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NLINK NODE NAME
   audit-log 3015 root    3w   REG    7,0 41943055     0   12 /srv/linux-lab-logs/app.log (deleted)
   ```
   `NLINK 0`, `FD 3w` (descriptor 3, open for writing), 40 MiB.
3. **Without lsof.** Every open file is a symlink under `/proc/PID/fd/`. Deleted ones end in ` (deleted)`: `ls -l /proc/*/fd/ 2>/dev/null | grep deleted`. `stat -L /proc/PID/fd/3` shows the size and `links=0`.

## Root cause

The file was unlinked, but `audit-logger` still holds it open. Deleting a name does not free space; closing the last descriptor does.

## Fix

`fix.sh` does it in two steps, without restarting the app:

1. **Free the space now:** `: > /proc/PID/fd/3` truncates the deleted file through the process's own descriptor. `df` drops at once.
2. **Make the app let go:** `kill -HUP PID`. This logger reopens its log on SIGHUP (many daemons do), so it creates a fresh `app.log` and closes the deleted one.

If the app does not support a reopen signal, restart it in a quiet moment.

## Prevention

- Rotate logs with logrotate. Use `postrotate` to send the reopen signal, or `copytruncate` for apps that cannot reopen (it can lose a few lines).
- Prefer logging to stdout and journald over the app writing its own files.
- Alert on disk usage before it is full, and teach the team: truncate (`: > file`), do not delete, a log that is still being written.

## What CI checks

After `break.sh`, `df` and `du` differ by 10 MiB or more and a deleted file is held open. `diagnose.sh` reports the PID, the deleted path and the descriptor number. After the fix, `df` and `du` agree within 10 MiB and `lsof +L1` shows nothing on the mount.

## Interview questions this covers

- **`df` says full, `du` says not. Why?** Deleted-but-open files are the classic answer. Others: files hidden under a mount point, and the root-reserved blocks on ext4.
- **How do you free the space without a restart?** Truncate through `/proc/PID/fd/N`.
- **What is an inode, and what is a hard link?** The inode holds the file's metadata and block map; a directory entry is a name pointing to it. The link count is how many names point to it. Data is freed when links and open descriptors both reach 0.
- **Why does `rm` not free space?** `rm` calls `unlink()`, which removes a name. Open descriptors still reference the inode.
