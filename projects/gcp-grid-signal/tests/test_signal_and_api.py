import datetime as dt

from fastapi.testclient import TestClient

from app import signal
from app.eirgrid import DUBLIN
from app.main import create_app
from app.store import MemoryStore

NOW = dt.datetime(2026, 10, 13, 14, 2, tzinfo=DUBLIN)


def slots():
    t = dt.datetime(2026, 1, 1)
    for _ in range(96):
        yield t.strftime("%H:%M")
        t += dt.timedelta(minutes=15)


def seeded_store(days=8):
    """A week where the grid is cleanest 02:00-04:00 (windy nights) and dirtiest at the 17:00-19:00 peak."""
    store = MemoryStore()
    for back in range(days):
        day = (NOW.date() - dt.timedelta(days=back)).isoformat()
        values = {}
        for s in slots():
            h = int(s[:2])
            if back == 0 and s > "13:45":
                break  # today only has readings up to now
            intensity = 120 if 2 <= h < 4 else 380 if 17 <= h < 19 else 250
            values[f"{s}/intensity"] = intensity
            values[f"{s}/wind"] = 2000.0
            values[f"{s}/demand"] = 5000.0
        store.merge_day(day, values)
    return store


def client(store):
    return TestClient(create_app(store, clock=lambda: NOW))


def test_band_thresholds():
    assert [signal.band(v) for v in (150, 250, 350)] == ["low", "medium", "high"]


def test_now_returns_latest_reading_with_wind_share_and_age():
    r = client(seeded_store()).get("/api/now").json()
    assert r["intensity_g_per_kwh"] == 250 and r["band"] == "medium"
    assert r["wind_share_pct"] == 40.0
    assert r["age_minutes"] == 17


def test_best_window_finds_the_windy_night():
    r = client(seeded_store()).get("/api/best-window", params={"duration_minutes": 120}).json()
    assert r["start"].startswith("2026-10-14T02:00")
    assert r["expected_band"] == "low"
    assert r["saving_pct_vs_now"] == 52.0


def test_best_window_skips_peak_when_window_is_short():
    r = client(seeded_store()).get("/api/best-window", params={"duration_minutes": 60, "within_hours": 6}).json()
    start = r["start"][11:16]
    assert not ("17:00" <= start < "19:00")


def test_best_window_needs_history():
    r = client(MemoryStore()).get("/api/best-window")
    assert r.status_code == 503


def test_history_is_sorted_and_limited():
    pts = client(seeded_store()).get("/api/history", params={"hours": 3}).json()["points"]
    assert pts == sorted(pts, key=lambda p: p["at"])
    assert 10 <= len(pts) <= 13


def test_health_is_ok_when_fresh_and_503_when_stale():
    store = seeded_store()
    assert client(store).get("/health").status_code == 200
    later = TestClient(create_app(store, clock=lambda: NOW + dt.timedelta(hours=3)))
    r = later.get("/health")
    assert r.status_code == 503 and r.json()["status"] == "stale"


def test_health_with_no_data_is_503():
    assert client(MemoryStore()).get("/health").status_code == 503


def test_badge_shows_live_value_and_colour():
    r = client(seeded_store()).get("/badge.svg")
    assert r.headers["content-type"].startswith("image/svg+xml")
    assert "250 g/kWh medium" in r.text


def test_badge_without_data_still_renders():
    assert "no data" in client(MemoryStore()).get("/badge.svg").text


def test_query_limits_are_enforced():
    c = client(seeded_store())
    assert c.get("/api/history", params={"hours": 1000}).status_code == 422
    assert c.get("/api/best-window", params={"duration_minutes": 5}).status_code == 422


def test_dashboard_is_served():
    assert "Grid Signal" in client(seeded_store()).get("/").text
