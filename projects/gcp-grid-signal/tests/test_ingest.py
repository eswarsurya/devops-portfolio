import datetime as dt

from app import ingest
from app.eirgrid import DUBLIN
from app.store import MemoryStore


def fake_fetch(day):
    return {day.isoformat(): {"10:00/intensity": 200.0}}


def test_ingest_fetches_today_and_writes(monkeypatch):
    monkeypatch.setattr(ingest, "fetch_day", fake_fetch)
    store = MemoryStore()
    written = ingest.run(store, dt.datetime(2026, 10, 13, 14, 0, tzinfo=DUBLIN))
    assert written == {"2026-10-13": 1}
    assert store.get_day("2026-10-13") == {"10:00/intensity": 200.0}


def test_just_after_midnight_also_fetches_yesterday(monkeypatch):
    monkeypatch.setattr(ingest, "fetch_day", fake_fetch)
    written = ingest.run(MemoryStore(), dt.datetime(2026, 10, 14, 0, 20, tzinfo=DUBLIN))
    assert set(written) == {"2026-10-13", "2026-10-14"}


def test_backfill_loads_previous_days(monkeypatch):
    monkeypatch.setattr(ingest, "fetch_day", fake_fetch)
    written = ingest.run(MemoryStore(), dt.datetime(2026, 10, 13, 14, 0, tzinfo=DUBLIN), backfill_days=7)
    assert len(written) == 8
