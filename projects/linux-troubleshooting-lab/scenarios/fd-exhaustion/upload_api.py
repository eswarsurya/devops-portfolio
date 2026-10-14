"""A service that reads a price list for every request.

mode=leak:  the bug. It opens the file and never closes it, so every request
            leaks one file descriptor until open() fails with EMFILE.
mode=fixed: uses a `with` block, so the descriptor is closed every time.
"""

import ctypes
import sys
import time

ctypes.CDLL(None).prctl(15, b"upload-api", 0, 0, 0)

conf = dict(line.strip().split("=", 1) for line in open(sys.argv[1]) if "=" in line)
mode = conf.get("mode", "leak")
data = conf["data"]
log = open(conf["log"], "w", buffering=1)

kept = []
n = 0
while True:
    n += 1
    try:
        if mode == "leak":
            f = open(data)
            f.read()
            kept.append(f)  # never closed
        else:
            with open(data) as f:
                f.read()
        if n % 20 == 0:
            log.write(f"request {n} ok\n")
    except OSError as e:
        log.write(f"request {n} ERROR {e}\n")
    time.sleep(0.02)
