"""A cache worker. In "leak" mode it never evicts, so memory grows until the
cgroup limit is hit and the kernel OOM killer steps in. In "bounded" mode it
keeps at most --max-mb of data."""

import ctypes
import sys
import time

ctypes.CDLL(None).prctl(15, b"cache-worker", 0, 0, 0)

conf = dict(line.strip().split("=", 1) for line in open(sys.argv[1]) if "=" in line)
mode = conf.get("mode", "leak")
max_chunks = int(conf.get("max_mb", "16")) // 2

cache = []
n = 0
while True:
    cache.append(bytearray(b"r") * (2 * 1024 * 1024))  # 2 MiB per "cached report", really written
    if mode == "bounded" and len(cache) > max_chunks:
        cache.pop(0)
    n += 1
    if n % 10 == 0:
        print(f"mode={mode} cached_mb={len(cache) * 2}", flush=True)
    time.sleep(0.05)
