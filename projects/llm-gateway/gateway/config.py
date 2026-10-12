from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass, field

import yaml


@dataclass
class Team:
    name: str
    key_sha256: str
    models: list[str]
    requests_per_minute: int = 60
    monthly_budget_usd: float = 10.0
    redact_pii: bool = True


@dataclass
class Price:
    input: float
    output: float
    long_context_threshold: int | None = None
    long_input: float | None = None
    long_output: float | None = None


@dataclass
class Config:
    teams: list[Team]
    pricing: dict[str, Price]
    cache_ttl: int = 600
    cache_max: int = 2000
    _by_hash: dict[str, Team] = field(default_factory=dict, repr=False)

    def __post_init__(self):
        self._by_hash = {t.key_sha256: t for t in self.teams}

    def team_for_key(self, api_key: str | None) -> Team | None:
        if not api_key:
            return None
        digest = hash_key(api_key)
        for h, team in self._by_hash.items():
            if hmac.compare_digest(h, digest):  # constant-time comparison
                return team
        return None


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def load(path: str) -> Config:
    with open(path) as f:
        raw = yaml.safe_load(f)
    return from_dict(raw)


def from_dict(raw: dict) -> Config:
    return Config(
        teams=[Team(**t) for t in raw.get("teams", [])],
        pricing={m: Price(**p) for m, p in raw.get("pricing", {}).items()},
        cache_ttl=raw.get("cache", {}).get("ttl_seconds", 600),
        cache_max=raw.get("cache", {}).get("max_entries", 2000),
    )
