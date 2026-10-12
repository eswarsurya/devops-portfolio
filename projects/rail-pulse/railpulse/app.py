"""Web API: live map, JSON snapshot, Server-Sent Events stream, Prometheus metrics.

RAILPULSE_REPLAY=tests/fixtures  -> cycle through saved snapshots (offline demo)
(default)                        -> poll the live Irish Rail API every 30s
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import os
import pathlib

from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from . import poller

STATIC = pathlib.Path(__file__).parent / "static"
state = poller.State()


def _replay_fetcher(folder: str):
    files = sorted(pathlib.Path(folder).glob("*.xml"))
    if not files:
        raise SystemExit(f"no .xml snapshots in {folder}")
    cycle = itertools.cycle(files)
    return lambda: next(cycle).read_text()


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    stop = asyncio.Event()
    replay = os.getenv("RAILPULSE_REPLAY")
    fetch = _replay_fetcher(replay) if replay else poller.fetch_feed
    interval = float(os.getenv("RAILPULSE_INTERVAL", "15" if replay else "30"))
    task = None
    if os.getenv("RAILPULSE_DISABLE_POLLER") != "1":
        task = asyncio.create_task(poller.run(state, fetch=fetch, interval=interval, stop=stop))
    yield
    stop.set()
    if task:
        await task


app = FastAPI(title="rail-pulse", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    """Ready only once we have data that isn't stale - k8s pulls us out of rotation otherwise."""
    if state.is_stale():
        response.status_code = 503
        return {"ready": False, "last_error": state.last_error}
    return {"ready": True}


@app.get("/api/snapshot")
def snapshot():
    return state.snapshot()


@app.get("/api/stream")
async def stream(request: Request):
    async def gen():
        seen = -1
        while not await request.is_disconnected():
            if state.version != seen:
                seen = state.version
                yield f"data: {json.dumps(state.snapshot())}\n\n"
            try:
                await asyncio.wait_for(state.changed.wait(), timeout=15)
            except TimeoutError:
                yield ": keep-alive\n\n"

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
def index():
    return FileResponse(STATIC / "index.html")
