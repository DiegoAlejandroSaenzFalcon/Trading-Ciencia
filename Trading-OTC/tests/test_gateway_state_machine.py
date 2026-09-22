"""Tests de integración: Connection State Machine (mock)."""

import asyncio

import pytest

from trading_otc.config import IQOptionAdapterConfig
from trading_otc.gateway import ConnectionState, IQOptionWebSocketGateway


@pytest.fixture
def config():
    return IQOptionAdapterConfig(
        email="test@demo.com",
        password="secret",
        demo=True,
        max_retries=3,
        base_backoff=0.01,
        max_backoff=0.1,
        cb_failure_threshold=2,
        cb_timeout=0.01,
    )


@pytest.fixture
def gateway(config):
    return IQOptionWebSocketGateway(config)


class TestGatewayStateMachine:
    @pytest.mark.asyncio
    async def test_initial_state_disconnected(self, gateway):
        assert gateway.connection_state == ConnectionState.DISCONNECTED

    @pytest.mark.asyncio
    async def test_circuit_opens_after_threshold(self, gateway):
        gateway._record_failure()
        gateway._record_failure()
        assert gateway.connection_state == ConnectionState.CIRCUIT_OPEN

    @pytest.mark.asyncio
    async def test_circuit_half_open_after_timeout(self, gateway):
        gateway._trip_circuit()
        assert gateway.connection_state == ConnectionState.CIRCUIT_OPEN
        await asyncio.sleep(0.02)
        gateway._check_circuit()
        assert gateway.connection_state == ConnectionState.HALF_OPEN

    @pytest.mark.asyncio
    async def test_circuit_closes_on_success_in_half_open(self, gateway):
        gateway._trip_circuit()
        await asyncio.sleep(0.02)
        gateway._check_circuit()  # HALF_OPEN
        gateway._record_success()
        assert gateway.connection_state == ConnectionState.CONNECTED

    @pytest.mark.asyncio
    async def test_circuit_stays_open_on_failure_in_half_open(self, gateway):
        gateway._trip_circuit()
        await asyncio.sleep(0.02)
        gateway._check_circuit()  # HALF_OPEN
        gateway._record_failure()
        assert gateway.connection_state == ConnectionState.CIRCUIT_OPEN

    @pytest.mark.asyncio
    async def test_rate_limiter_integration(self, gateway):
        # rest_limiter y ws_limiter inicializados
        assert gateway._rest_limiter.capacity == 30
        assert gateway._ws_limiter.capacity == 100
        await gateway._rest_limiter.take(1)
        assert await gateway._rest_limiter.available_tokens() == 29.0