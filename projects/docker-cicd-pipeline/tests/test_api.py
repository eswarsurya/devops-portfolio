import pytest
from fastapi.testclient import TestClient

from app.main import app, reset_store

client = TestClient(app)


@pytest.fixture(autouse=True)
def clean_store():
    reset_store()
    yield


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_ready():
    assert client.get("/ready").json() == {"ready": True}


def test_create_and_list_sorted_by_severity():
    client.post("/incidents", json={"title": "disk 80% on web-2", "severity": 3})
    client.post("/incidents", json={"title": "checkout API down", "severity": 1})
    items = client.get("/incidents").json()
    assert [i["severity"] for i in items] == [1, 3]
    assert items[0]["id"] == 2


def test_validation_rejects_bad_severity():
    r = client.post("/incidents", json={"title": "bad", "severity": 9})
    assert r.status_code == 422


def test_resolve_and_open_only_filter():
    client.post("/incidents", json={"title": "cert expiring", "severity": 2})
    r = client.post("/incidents/1/resolve")
    assert r.json()["resolved"] is True
    assert client.get("/incidents?open_only=true").json() == []


def test_resolve_missing_returns_404():
    assert client.post("/incidents/999/resolve").status_code == 404


def test_metrics_exposed_with_route_labels():
    client.get("/health")
    body = client.get("/metrics").text
    assert "http_requests_total" in body
    assert 'path="/health"' in body
