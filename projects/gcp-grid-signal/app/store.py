"""Where readings live. One document per Dublin-local day, so a 7-day lookup is 8 reads, not 672.

Document shape: {"values": {"HH:MM/metric": float, ...}, "updated_at": iso8601}
"""

from __future__ import annotations

import datetime as dt
import os
from typing import Protocol


class Store(Protocol):
    def get_day(self, day: str) -> dict[str, float]: ...
    def merge_day(self, day: str, values: dict[str, float]) -> None: ...


class MemoryStore:
    """For tests, local runs and the CI smoke test."""

    def __init__(self) -> None:
        self.days: dict[str, dict[str, float]] = {}

    def get_day(self, day: str) -> dict[str, float]:
        return dict(self.days.get(day, {}))

    def merge_day(self, day: str, values: dict[str, float]) -> None:
        self.days.setdefault(day, {}).update(values)


class FirestoreStore:
    def __init__(self, collection: str = "days") -> None:
        from google.cloud import firestore  # imported here so tests don't need GCP libraries loaded

        self._col = firestore.Client().collection(collection)

    def get_day(self, day: str) -> dict[str, float]:
        snap = self._col.document(day).get()
        return dict((snap.to_dict() or {}).get("values", {})) if snap.exists else {}

    def merge_day(self, day: str, values: dict[str, float]) -> None:
        self._col.document(day).set(
            {"values": values, "updated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds")},
            merge=True,
        )


def from_env() -> Store:
    kind = os.environ.get("STORE", "firestore")
    if kind == "memory":
        return MemoryStore()
    if kind == "firestore":
        return FirestoreStore(os.environ.get("FIRESTORE_COLLECTION", "days"))
    raise ValueError(f"unknown STORE={kind!r} (use firestore or memory)")
