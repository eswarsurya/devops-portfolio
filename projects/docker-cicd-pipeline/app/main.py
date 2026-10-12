"""A small 'incident tracker' API.

The app is deliberately simple. The point of this repo is how it is built,
tested, containerised, scanned and shipped, not the business logic.
"""

import os
import time
from threading import Lock

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

APP_VERSION = os.getenv("APP_VERSION", "dev")

app = FastAPI(title="incident-api", version=APP_VERSION)

# --- Prometheus metrics (scraped at /metrics) ---------------------------------
REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request latency in seconds", ["path"])


@app.middleware("http")
async def record_metrics(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Use the route template (/incidents/{incident_id}), not the raw path,
    # so metric cardinality stays bounded.
    route = request.scope.get("route")
    path = route.path if route else "unmatched"
    LATENCY.labels(path=path).observe(time.perf_counter() - start)
    REQUESTS.labels(request.method, path, response.status_code).inc()
    return response


# --- In-memory store (swap for Postgres later) --------------------------------
class IncidentIn(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    severity: int = Field(ge=1, le=4, description="1 = critical, 4 = low")


class Incident(IncidentIn):
    id: int
    resolved: bool = False


_db: dict[int, Incident] = {}
_next_id = 1
_lock = Lock()


def reset_store() -> None:
    """Used by tests."""
    global _next_id
    with _lock:
        _db.clear()
        _next_id = 1


# --- Routes -------------------------------------------------------------------
@app.get("/health")
def health():
    """Liveness: the process is up."""
    return {"status": "ok", "version": APP_VERSION}


@app.get("/ready")
def ready():
    """Readiness: we can serve traffic (would check DB here)."""
    return {"ready": True}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/incidents", response_model=list[Incident])
def list_incidents(open_only: bool = False):
    items = sorted(_db.values(), key=lambda i: (i.severity, i.id))
    return [i for i in items if not (open_only and i.resolved)]


@app.post("/incidents", response_model=Incident, status_code=201)
def create_incident(body: IncidentIn):
    global _next_id
    with _lock:
        incident = Incident(id=_next_id, **body.model_dump())
        _db[incident.id] = incident
        _next_id += 1
    return incident


@app.post("/incidents/{incident_id}/resolve", response_model=Incident)
def resolve_incident(incident_id: int):
    incident = _db.get(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="incident not found")
    incident.resolved = True
    return incident
