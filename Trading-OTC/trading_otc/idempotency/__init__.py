"""Idempotency Keys para evitar duplicados en reintentos."""

import hashlib
import time
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class IdempotencyKey:
    """Clave determinística: strategy_id + signal_hash + time_window."""

    strategy_id: str
    signal_hash: str
    time_window_seconds: int = 300

    def to_string(self) -> str:
        window = int(time.time() / self.time_window_seconds)
        raw = f"{self.strategy_id}:{self.signal_hash}:{window}"
        return hashlib.sha256(raw.encode()).hexdigest()[:32]

    @classmethod
    def from_components(cls, strategy_id: str, signal_hash: str, time_window_seconds: int = 300):
        return cls(strategy_id, signal_hash, time_window_seconds)


def generate_idempotency_key(strategy_id: str, signal_hash: str, time_window_seconds: int = 300) -> str:
    """Helper directo."""
    return IdempotencyKey(strategy_id, signal_hash, time_window_seconds).to_string()


class IdempotencyStore:
    """Almacén en memoria con TTL (producción → Redis SET NX EX)."""

    def __init__(self, default_ttl: int = 300):
        self._store: dict[str, float] = {}
        self._default_ttl = default_ttl

    def try_acquire(self, key: str, ttl: int | None = None) -> bool:
        now = time.time()
        ttl = ttl or self._default_ttl

        expired = [k for k, exp in self._store.items() if exp < now]
        for k in expired:
            del self._store[k]

        if key in self._store:
            return False

        self._store[key] = now + ttl
        return True

    def release(self, key: str) -> None:
        self._store.pop(key, None)

    def is_acquired(self, key: str) -> bool:
        now = time.time()
        if key in self._store and self._store[key] > now:
            return True
        self._store.pop(key, None)
        return False
