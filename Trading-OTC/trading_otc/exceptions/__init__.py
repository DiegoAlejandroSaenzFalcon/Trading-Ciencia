"""Excepciones específicas del adapter IQ Option."""

from .auth import IQOptionAuthError
from .base import IQOptionError
from .circuit import IQOptionCircuitOpenError
from .connection import IQOptionConnectionError
from .order import IQOptionOrderError
from .rate_limit import IQOptionRateLimitError
from .validation import IQOptionValidationError

__all__ = [
    "IQOptionError",
    "IQOptionAuthError",
    "IQOptionConnectionError",
    "IQOptionRateLimitError",
    "IQOptionCircuitOpenError",
    "IQOptionOrderError",
    "IQOptionValidationError",
]
