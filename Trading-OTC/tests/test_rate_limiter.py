"""Tests unitarios: TokenBucketAsync."""

import asyncio

import pytest

from trading_otc.rate_limiter import TokenBucketAsync


class TestTokenBucketAsync:
    @pytest.mark.asyncio
    async def test_immediate_take_when_available(self):
        bucket = TokenBucketAsync(capacity=10, refill_rate=5.0)
        waited = await bucket.take(3)
        assert waited == 0.0
        assert await bucket.available_tokens() == 7.0

    @pytest.mark.asyncio
    async def test_blocks_when_empty(self):
        bucket = TokenBucketAsync(capacity=2, refill_rate=10.0)
        await bucket.take(2)
        start = asyncio.get_event_loop().time()
        await bucket.take(1)
        elapsed = asyncio.get_event_loop().time() - start
        assert elapsed >= 0.08

    @pytest.mark.asyncio
    async def test_try_take_no_block(self):
        bucket = TokenBucketAsync(capacity=1, refill_rate=1.0)
        assert await bucket.try_take(1) is True
        assert await bucket.try_take(1) is False

    @pytest.mark.asyncio
    async def test_refill_over_time(self):
        bucket = TokenBucketAsync(capacity=5, refill_rate=5.0)
        await bucket.take(5)
        await asyncio.sleep(0.5)
        assert await bucket.available_tokens() >= 2.0

    @pytest.mark.asyncio
    async def test_concurrent_access(self):
        """Thread-safety: múltiples coroutines tomando tokens."""
        bucket = TokenBucketAsync(capacity=100, refill_rate=50.0)
        async def take_many():
            for _ in range(10):
                await bucket.take(1)
        await asyncio.gather(*[take_many() for _ in range(5)])
        assert await bucket.available_tokens() == 50.0