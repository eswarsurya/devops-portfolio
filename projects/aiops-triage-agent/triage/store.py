"""In-memory incident store with a live event feed per incident.

Good enough for one replica. To scale out, swap for Redis (streams for events,
a hash per incident) - the interface stays the same.
"""

from __future__ import annotations

import itertools
import threading
import time
from dataclasses import dataclass, field


@dataclass
class Incident:
    id: int
    alertname: str
    namespace: str
    status: str = "investigating"  # investigating -> diagnosed -> approved/rejected/failed
    events: list[dict] = field(default_factory=list)
    diagnosis: dict | None = None
    action_result: str | None = None
    created: float = field(default_factory=time.time)

    def summary(self) -> dict:
        return {
            "id": self.id,
            "alertname": self.alertname,
            "namespace": self.namespace,
            "status": self.status,
            "created": self.created,
            "summary": (self.diagnosis or {}).get("summary"),
            "confidence": (self.diagnosis or {}).get("confidence"),
        }


class Store:
    def __init__(self, max_incidents: int = 50):
        self._incidents: dict[int, Incident] = {}
        self._ids = itertools.count(1)
        self._cond = threading.Condition()
        self._max = max_incidents

    def create(self, alertname: str, namespace: str) -> Incident:
        with self._cond:
            inc = Incident(id=next(self._ids), alertname=alertname, namespace=namespace)
            self._incidents[inc.id] = inc
            while len(self._incidents) > self._max:  # drop the oldest
                self._incidents.pop(min(self._incidents))
            return inc

    def get(self, incident_id: int) -> Incident | None:
        return self._incidents.get(incident_id)

    def list(self) -> list[dict]:
        return [i.summary() for i in sorted(self._incidents.values(), key=lambda i: -i.id)]

    def add_event(self, incident_id: int, event: dict) -> None:
        with self._cond:
            inc = self._incidents.get(incident_id)
            if inc is None:
                return
            event = {**event, "ts": time.time(), "seq": len(inc.events)}
            inc.events.append(event)
            if event["type"] == "diagnosis":
                inc.diagnosis = event["diagnosis"]
                inc.status = "diagnosed"
            self._cond.notify_all()

    def set_status(self, incident_id: int, status: str, result: str | None = None) -> None:
        with self._cond:
            inc = self._incidents[incident_id]
            inc.status = status
            if result is not None:
                inc.action_result = result
            inc.events.append(
                {
                    "type": "status",
                    "status": status,
                    "result": result,
                    "ts": time.time(),
                    "seq": len(inc.events),
                }
            )
            self._cond.notify_all()

    def wait_for_events(self, incident_id: int, after: int, timeout: float = 15.0) -> list[dict]:
        """Block until there are events with seq >= after (or timeout). Used by SSE."""
        with self._cond:
            inc = self._incidents.get(incident_id)
            if inc is None:
                return []
            if len(inc.events) <= after:
                self._cond.wait(timeout)
            return inc.events[after:]
