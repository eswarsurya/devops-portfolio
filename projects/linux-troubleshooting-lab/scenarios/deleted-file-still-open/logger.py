"""An app that writes its own log file and only reopens it on SIGHUP
(the way many daemons expect logrotate to tell them)."""

import ctypes
import signal
import sys
import time

ctypes.CDLL(None).prctl(15, b"audit-logger", 0, 0, 0)

path = sys.argv[1]
burst_mb = int(sys.argv[2]) if len(sys.argv) > 2 else 0
log = open(path, "a")


def reopen(_signum, _frame):
    global log
    log.close()
    log = open(path, "a")
    log.write("log reopened after SIGHUP\n")
    log.flush()


signal.signal(signal.SIGHUP, reopen)

# A burst of debug output, the reason the log got big.
line = "DEBUG " + "x" * 1017 + "\n"  # 1 KiB
for _ in range(burst_mb * 1024):
    log.write(line)
log.flush()

while True:
    log.write("INFO heartbeat\n")
    log.flush()
    time.sleep(1)
