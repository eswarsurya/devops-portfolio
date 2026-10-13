"""Cloud Run Job entry point: pull today's (and, just after midnight, yesterday's) readings into the store.

Run: python -m app.ingest   (BACKFILL_DAYS=7 to load a week of history on first deploy)
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys

from .eirgrid import DUBLIN, FeedError, fetch_day
from .store import Store, from_env


def run(store: Store, now: dt.datetime, backfill_days: int = 0) -> dict:
    days = {now.date()}
    if now.hour < 1:  # late readings for yesterday arrive just after midnight
        days.add(now.date() - dt.timedelta(days=1))
    days |= {now.date() - dt.timedelta(days=i) for i in range(1, backfill_days + 1)}
    written = {}
    for day in sorted(days):
        for d, values in fetch_day(day).items():
            store.merge_day(d, values)
            written[d] = written.get(d, 0) + len(values)
    return written


def main() -> int:
    now = dt.datetime.now(DUBLIN)
    try:
        written = run(from_env(), now, int(os.environ.get("BACKFILL_DAYS", "0")))
    except FeedError as exc:
        # Structured log line: Cloud Logging picks up severity, and the alert policy matches on it.
        print(json.dumps({"severity": "ERROR", "message": f"ingest failed: {exc}"}), flush=True)
        return 1
    print(json.dumps({"severity": "INFO", "message": "ingest ok", "values_written": written}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
