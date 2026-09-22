"""Error de rate limit."""

from .base import IQOptionError


class IQOptionRateLimitError(IQOptionError):
    """Rate limit excedido (HTTP 429 o WS throttling)."""

    def __init__(
        self,
        message: str = "Rate limit excedido",
        retry_after: float = 1.0,
        details: dict = None,
    ):
        super().__init__(message, "IQOPTION_RATE_LIMIT", details)
        self.retry_after = retry_after
