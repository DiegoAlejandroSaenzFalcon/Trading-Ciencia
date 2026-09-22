"""IQOptionWebSocketGateway - Implementación principal."""

import asyncio
import logging
from abc import ABC, abstractmethod
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import List, Optional, Protocol

from ..config import IQOptionAdapterConfig
from ..exceptions import (
    IQOptionAuthError,
    IQOptionCircuitOpenError,
    IQOptionConnectionError,
    IQOptionError,
    IQOptionRateLimitError,
)
from ..fsm import OrderState, OrderStateMachine
from ..idempotency import IdempotencyStore, generate_idempotency_key
from ..models import (
    IQOptionAccount,
    IQOptionCandle,
    IQOptionOrder,
    IQOptionTick,
    OrderCommand,
    OrderSide,
    OrderStatus,
    OrderType,
)
from ..rate_limiter import TokenBucketAsync
from ..reconciliation import IBrokerClient, IOrderStore, ReconciliationJob

logger = logging.getLogger(__name__)


class IMarketDataCallback(Protocol):
    async def on_tick(self, tick: IQOptionTick) -> None: ...
    async def on_candle(self, candle: IQOptionCandle) -> None: ...


class IOrderCallback(Protocol):
    async def on_order_update(self, order: IQOptionOrder) -> None: ...


class ConnectionState(str, Enum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    AUTHENTICATING = "authenticating"
    AUTHENTICATED = "authenticated"
    SUBSCRIBING = "subscribing"
    CONNECTED = "connected"
    RECONNECTING = "reconnecting"
    CIRCUIT_OPEN = "circuit_open"
    HALF_OPEN = "half_open"
    DISCONNECTING = "disconnecting"


class IQOptionWebSocketGateway:
    """Gateway principal IQ Option (WebSocket + REST, resiliente)."""

    def __init__(self, config: IQOptionAdapterConfig):
        self._config = config
        self._state = ConnectionState.DISCONNECTED
        self._ws = None
        self._rest_session = None

        self._tick_callbacks: list[IMarketDataCallback] = []
        self._candle_callbacks: list[IMarketDataCallback] = []
        self._order_callbacks: list[IOrderCallback] = []

        self._rest_limiter = TokenBucketAsync(config.rest_rps, config.rest_rps)
        self._ws_limiter = TokenBucketAsync(config.ws_rps, config.ws_rps)
        self._idempotency = IdempotencyStore(config.idempotency_ttl_seconds)
        self._circuit_failures = 0
        self._circuit_open_at: datetime | None = None

        self._order_fsm: dict[str, OrderStateMachine] = {}
        self._recon_job: ReconciliationJob | None = None

    @property
    def connection_state(self) -> ConnectionState:
        return self._state

    def _set_state(self, new_state: ConnectionState) -> None:
        old = self._state
        self._state = new_state
        logger.info("Connection state: %s → %s", old, new_state)

    async def connect(self) -> None:
        if self._state in (ConnectionState.CONNECTED, ConnectionState.CONNECTING):
            return
        self._set_state(ConnectionState.CONNECTING)
        raise NotImplementedError("connect() - TDD: test primero")

    async def disconnect(self) -> None:
        self._set_state(ConnectionState.DISCONNECTING)
        raise NotImplementedError("disconnect() - TDD: test primero")

    async def subscribe_ticks(self, symbols: list[str]) -> None:
        raise NotImplementedError("subscribe_ticks() - TDD: test primero")

    async def subscribe_candles(self, symbols: list[str], timeframe: int) -> None:
        raise NotImplementedError("subscribe_candles() - TDD: test primero")

    def on_tick(self, callback: IMarketDataCallback) -> None:
        self._tick_callbacks.append(callback)

    def on_candle(self, callback: IMarketDataCallback) -> None:
        self._candle_callbacks.append(callback)

    def on_order_update(self, callback: IOrderCallback) -> None:
        self._order_callbacks.append(callback)

    async def place_order(self, cmd: OrderCommand) -> IQOptionOrder:
        raise NotImplementedError("place_order() - TDD: test primero")

    async def cancel_order(self, client_order_id: str) -> bool:
        raise NotImplementedError("cancel_order() - TDD: test primero")

    async def get_order_status(self, client_order_id: str) -> IQOptionOrder | None:
        raise NotImplementedError("get_order_status() - TDD: test primero")

    async def get_account(self) -> IQOptionAccount:
        raise NotImplementedError("get_account() - TDD: test primero")

    async def get_balance(self) -> float:
        acc = await self.get_account()
        return float(acc.balance)

    def _record_success(self) -> None:
        self._circuit_failures = 0
        if self._state == ConnectionState.HALF_OPEN:
            self._set_state(ConnectionState.CONNECTED)

    def _record_failure(self) -> None:
        self._circuit_failures += 1
        if self._state == ConnectionState.HALF_OPEN:
            # En HALF_OPEN, cualquier fallo vuelve a abrir el circuit
            self._trip_circuit()
        elif self._circuit_failures >= self._config.cb_failure_threshold:
            self._trip_circuit()

    def _trip_circuit(self) -> None:
        self._circuit_open_at = datetime.utcnow()
        self._set_state(ConnectionState.CIRCUIT_OPEN)
        logger.warning("Circuit breaker ABIERTO tras %d fallos", self._circuit_failures)

    def _check_circuit(self) -> None:
        if self._state == ConnectionState.CIRCUIT_OPEN:
            if self._circuit_open_at:
                elapsed = (datetime.utcnow() - self._circuit_open_at).total_seconds()
                if elapsed >= self._config.cb_timeout:
                    self._set_state(ConnectionState.HALF_OPEN)
                    logger.info("Circuit breaker HALF_OPEN (test request)")
                    return
            raise IQOptionCircuitOpenError(
                retry_after=self._config.cb_timeout,
                details={"failures": self._circuit_failures},
            )

    def set_reconciliation_job(self, job: ReconciliationJob) -> None:
        self._recon_job = job

    async def start_reconciliation(self) -> None:
        if self._recon_job:
            await self._recon_job.start()

    async def stop_reconciliation(self) -> None:
        if self._recon_job:
            await self._recon_job.stop()
