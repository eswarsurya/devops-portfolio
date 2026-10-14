"""A consumer and a producer that talk through a named pipe (FIFO).

consumer: reads jobs line by line and records each one in a status file.
producer --stuck: opens the pipe for writing, then hangs before writing
                  anything (think: waiting on a lock or a slow upstream).
producer:         writes three jobs and exits.
"""

import ctypes
import os
import sys
import time

libc = ctypes.CDLL(None)
role, fifo, status = sys.argv[1], sys.argv[2], sys.argv[3]

if role == "consumer":
    libc.prctl(15, b"job-consumer", 0, 0, 0)
    with open(status, "a") as s:
        s.write("waiting for jobs\n")
    while True:
        # open() blocks until a writer appears; read blocks until data or EOF.
        with open(fifo) as f:
            for line in f:
                with open(status, "a") as s:
                    s.write(f"processed {line.strip()} at {time.strftime('%H:%M:%S')}\n")
else:
    libc.prctl(15, b"job-producer", 0, 0, 0)
    fd = os.open(fifo, os.O_WRONLY)
    if "--stuck" in sys.argv:
        time.sleep(10**6)  # holds the write end open, never writes
    for i in range(1, 4):
        os.write(fd, f"job-{i}\n".encode())
    os.close(fd)
