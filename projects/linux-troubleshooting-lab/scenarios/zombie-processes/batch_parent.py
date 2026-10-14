"""A batch runner that forks a child per job.

mode=noreap: the bug. Children exit but the parent never calls wait(), so each
             one stays in the process table as a zombie (state Z).
mode=reap:   the fix. A SIGCHLD handler reaps every finished child.
"""

import ctypes
import os
import signal
import sys
import time

libc = ctypes.CDLL(None)
libc.prctl(15, b"batch-parent", 0, 0, 0)

conf = dict(line.strip().split("=", 1) for line in open(sys.argv[1]) if "=" in line)
mode = conf.get("mode", "noreap")


def reap(_signum, _frame):
    # Reap every child that has finished. WNOHANG: never block in a handler.
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


if mode == "reap":
    signal.signal(signal.SIGCHLD, reap)

jobs = 0
while True:
    if jobs < 8:
        pid = os.fork()
        if pid == 0:
            libc.prctl(15, b"batch-child", 0, 0, 0)
            os._exit(0)  # the "job" is done at once
        jobs += 1
        print(f"mode={mode} started job {jobs} as pid {pid}", flush=True)
    time.sleep(0.25)
