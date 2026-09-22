"""Modelos de datos de mercado (ticks, velas)."""

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class IQOptionTick(BaseModel):
    """Tick de precio en tiempo real."""

    model_config = ConfigDict(frozen=True)

    symbol: str
    bid: Decimal
    ask: Decimal
    timestamp: datetime
    source: str = "iqoption"


class IQOptionCandle(BaseModel):
    """Vela OHLCV."""

    model_config = ConfigDict(frozen=True)

    symbol: str
    timeframe: int
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Decimal
    timestamp: datetime
    source: str = "iqoption"
