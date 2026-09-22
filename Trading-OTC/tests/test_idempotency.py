"""Tests unitarios: IdempotencyKey + IdempotencyStore."""

import time

from trading_otc.idempotency import (
    IdempotencyStore,
    generate_idempotency_key,
)


class TestIdempotencyKey:
    def test_deterministic_same_window(self):
        k1 = generate_idempotency_key("strat1", "signal_abc")
        k2 = generate_idempotency_key("strat1", "signal_abc")
        assert k1 == k2

    def test_different_strategy_different_key(self):
        k1 = generate_idempotency_key("strat1", "signal_abc")
        k2 = generate_idempotency_key("strat2", "signal_abc")
        assert k1 != k2

    def test_different_signal_different_key(self):
        k1 = generate_idempotency_key("strat1", "signal_abc")
        k2 = generate_idempotency_key("strat1", "signal_xyz")
        assert k1 != k2

    def test_key_length(self):
        key = generate_idempotency_key("a", "b")
        assert len(key) == 32  # SHA256 truncated


class TestIdempotencyStore:
    def test_acquire_new_key(self):
        store = IdempotencyStore(default_ttl=60)
        assert store.try_acquire("key1") is True
        assert store.try_acquire("key1") is False

    def test_release_allows_reacquire(self):
        store = IdempotencyStore(default_ttl=60)
        store.try_acquire("key1")
        store.release("key1")
        assert store.try_acquire("key1") is True

    def test_ttl_expiry(self):
        store = IdempotencyStore(default_ttl=1)
        store.try_acquire("key1")
        time.sleep(1.1)
        assert store.try_acquire("key1") is True

    def test_is_acquired(self):
        store = IdempotencyStore(default_ttl=60)
        store.try_acquire("key1")
        assert store.is_acquired("key1") is True
        store.release("key1")
        assert store.is_acquired("key1") is False