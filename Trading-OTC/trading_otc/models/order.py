"""Modelos de órdenes para IQ Option."""

from datetime import datetime
from decimal import Decimal
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class OrderSide(str, Enum):
    CALL = "call"
    PUT = "put"


class OrderType(str, Enum):
    BINARY = "binary"
    DIGITAL = "digital"


class OrderStatus(str, Enum):
    PENDING_VALIDATION = "pending_validation"
    VALIDATED = "validated"
    SUBMITTED = "submitted"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    REJECTED = "rejected"
    CANCEL_PENDING = "cancel_pending"
    CANCELLED = "cancelled"
    SETTLED = "settled"


class IQOptionOrder(BaseModel):
    """Orden enviada a IQ Option."""

    model_config = ConfigDict(frozen=True)

    # Identidad
    idempotency_key: str
    client_order_id: str

    # Parámetros
    symbol: str
    side: OrderSide
    amount: Decimal
    duration: int
    order_type: OrderType = OrderType.BINARY

    # Estado
    status: OrderStatus = OrderStatus.PENDING_VALIDATION
    broker_order_id: str | None = None

    # Timestamps
    created_at: datetime = Field(default_factory=datetime.utcnow)
    submitted_at: datetime | None = None
    filled_at: datetime | None = None
    updated_at: datetime = Field(default_factory=datetime.utcnow)

    # Resultado
    fill_price: Decimal | None = None
    fill_amount: Decimal | None = None
    profit: Decimal | None = None
    error_message: str | None = None

    # Metadata
    strategy_id: str | None = None
    signal_hash: str | None = None
    metadata: dict = Field(default_factory=dict)


class OrderCommand(BaseModel):
    """Comando para colocar orden (use case → adapter)."""

    symbol: str
    side: OrderSide
    amount: Decimal
    duration: int
    order_type: OrderType = OrderType.BINARY
    idempotency_key: str | None = None
    strategy_id: str | None = None
    signal_hash: str | None = None
    metadata: dict = Field(default_factory=dict)
