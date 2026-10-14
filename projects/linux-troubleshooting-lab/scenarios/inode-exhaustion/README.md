# Inode exhaustion

**Reported symptom:** "Uploads fail with 'No space left on device', but `df -h` says the disk is nearly empty."

## What `break.sh` does

Creates a 64 MiB ext4 filesystem with only 1024 inodes (`mkfs.ext4 -N 1024`), loop-mounts it at `/srv/linux-lab-data`, and lets a "session cache" create one empty file per session in `app/cache/sessions/` until the filesystem refuses. In CI that took about a thousand files.

## Investigate

1. **Reproduce.** `touch /srv/linux-lab-data/app/uploads/new-upload` fails with `No space left on device` (ENOSPC).
2. **Space looks fine.** `df -h` showed the filesystem at 1% used (60K of 60M).
3. **Inodes do not.** Every file, directory and symlink needs an inode, and ext4 fixes the number when the filesystem is created. `df -i` showed `IUse% 100%` for `/srv/linux-lab-data`.
   `stat -f` gives the live numbers. From CI: `inodes total=1024 free=0, blocks total=15285 free=15270`. (Do not trust `tune2fs -l` on a mounted filesystem for this; its free count can be out of date.)
4. **Where are all the files?** Count entries per directory:
   ```
   find /srv/linux-lab-data -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -5
   ```
   One directory held almost all of them: `app/cache/sessions`. `du -sh` on it is tiny, which is the point: the files cost inodes, not blocks.

## Root cause

An application writes many tiny files and never cleans them up. The filesystem ran out of inodes long before it ran out of space.

## Fix

`fix.sh` deletes the session files with `find ... -name 'sess_*' -delete`. On a real system, delete only what is stale (`-mmin +60` or the app's session timeout), and be careful: `rm sess_*` on a huge directory fails with "Argument list too long", while `find -delete` does not.

## Prevention

- A cleanup job (systemd timer, `systemd-tmpfiles` with an age, or the app's own expiry).
- Monitor inode use as well as space: `node_filesystem_files_free` in Prometheus node_exporter.
- For workloads with millions of small files, choose the inode ratio at `mkfs` time, or use XFS, which allocates inodes dynamically.

## What CI checks

After `break.sh`, `verify.sh` fails because a new file cannot be written. `diagnose.sh` reports the full mount, `100%` inode use, the directory holding the files and the exact error. After the fix, a new file can be written and inode use is under 90%.

## Interview questions this covers

- **"No space left on device" but `df` shows space. What do you check?** `df -i` for inodes. Then deleted-but-open files and reserved blocks.
- **What is stored in an inode?** Owner, permissions, timestamps, size, link count and where the data blocks are. Not the file name; that lives in the directory.
- **How do you find the directory with the most files?** `find <mount> -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head`.
- **Can you add inodes to an existing ext4 filesystem?** Not directly. You recreate it with a different ratio or migrate the data.
