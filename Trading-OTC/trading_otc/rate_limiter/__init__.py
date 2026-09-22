"""Token Bucket async thread-safe para rate limiting."""

import asyncio
import time
from dataclasses import dataclass, field


@dataclass
class TokenBucketAsync:
    """Token Bucket asíncrono (asyncio.Lock)."""

    capacity: int
    refill_rate: float
    _tokens: float = field(init=False)
    _last_refill: float = field(init=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, init=False)

    def __post_init__(self):
        self._tokens = float(self.capacity)
        self._last_refill = time.monotonic()

    async def take(self, tokens: int = 1) -> float:
        """Toma tokens, bloquea hasta disponible. Retorna segundos esperados."""
        waited = 0.0
        while True:
            async with self._lock:
                now = time.monotonic()
                elapsed = now - self._last_refill
                self._tokens = min(self.capacity, self._tokens + elapsed * self.refill_rate)
                self._last_refill = now

                if self._tokens >= tokens:
                    self._tokens -= tokens
                    return waited

                needed = tokens - self._tokens
                wait_time = needed / self.refill_rate

            await asyncio.sleep(wait_time)
            waited += wait_time

    async def try_take(self, tokens: int = 1) -> bool:
        """Intenta tomar sin bloquear."""
        async with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_refill
            self._tokens = min(self.capacity, self._tokens + elapsed * self.refill_rate)
            self._last_refill = now

            if self._tokens >= tokens:
                self._tokens -= tokens
                return True
            return False

    async def available_tokens(self) -> float:
        async with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_refill
            return min(self.capacity, self._tokens + elapsed * self.refill_rate)
