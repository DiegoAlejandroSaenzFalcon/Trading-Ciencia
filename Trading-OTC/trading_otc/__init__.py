"""
IQ Option Adapter para Trading Science Framework.

Trading-OTC: Adapter completo para IQ Option (Binary/OTC/Digital)
con WebSocket + REST, Circuit Breaker, Rate Limiter, Idempotency,
Order FSM y Reconciliation.
"""

from .config import IQOptionAdapterConfig
from .exceptions import (
    IQOptionAuthError,
    IQOptionCircuitOpenError,
    IQOptionConnectionError,
    IQOptionError,
    IQOptionOrderError,
    IQOptionRateLimitError,
    IQOptionValidationError,
)
from .fsm import VALID_TRANSITIONS, OrderState, OrderStateMachine
from .gateway import ConnectionState, IQOptionWebSocketGateway
from .idempotency import IdempotencyKey, IdempotencyStore, generate_idempotency_key
from .models import (
    IQOptionAccount,
    IQOptionCandle,
    IQOptionOrder,
    IQOptionTick,
    OrderCommand,
    OrderSide,
    OrderStatus,
    OrderType,
)
from .rate_limiter import TokenBucketAsync
from .reconciliation import IBrokerClient, IOrderStore, ReconciliationJob, ReconciliationResult

__all__ = [
    "IQOptionAdapterConfig",
    "OrderSide",
    "OrderType",
    "OrderStatus",
    "IQOptionOrder",
    "OrderCommand",
    "IQOptionTick",
    "IQOptionCandle",
    "IQOptionAccount",
    "IQOptionError",
    "IQOptionAuthError",
    "IQOptionConnectionError",
    "IQOptionRateLimitError",
    "IQOptionCircuitOpenError",
    "IQOptionOrderError",
    "IQOptionValidationError",
    "TokenBucketAsync",
    "IdempotencyKey",
    "generate_idempotency_key",
    "IdempotencyStore",
    "OrderStateMachine",
    "OrderState",
    "VALID_TRANSITIONS",
    "ReconciliationJob",
    "ReconciliationResult",
    "IOrderStore",
    "IBrokerClient",
    "IQOptionWebSocketGateway",
    "ConnectionState",
]

__version__ = "0.1.0"