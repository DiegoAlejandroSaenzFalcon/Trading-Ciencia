"""Modelo de cuenta IQ Option."""

from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict


class IQOptionAccount(BaseModel):
    """Info de cuenta (balance, tipo)."""

    model_config = ConfigDict(frozen=True)

    user_id: str
    balance: Decimal
    currency: str = "USD"
    is_demo: bool = True
    account_type: Literal["PRACTICE", "REAL"] = "PRACTICE"
