import pytest
from app import create_app

@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setenv("DEPENDENCY_STATUS", "ok")
    return create_app({"TESTING": True}).test_client()

def test_root_identifies_service(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.get_json()["service"] == "incident-ready-api"

def test_liveness_is_successful(client):
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"

def test_readiness_is_successful(client):
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ready"

def test_readiness_fails_when_dependency_is_unhealthy(client, monkeypatch):
    monkeypatch.setenv("DEPENDENCY_STATUS", "unavailable")
    r = client.get("/health/ready")
    assert r.status_code == 503
    assert r.get_json()["status"] == "not_ready"

def test_status_includes_version_and_uptime(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "test-build")
    payload = client.get("/api/v1/status").get_json()
    assert payload["version"] == "test-build"
    assert payload["uptime_seconds"] >= 0

def test_unknown_route_returns_json_404(client):
    r = client.get("/does-not-exist")
    assert r.status_code == 404
    assert r.get_json()["error"] == "not_found"
