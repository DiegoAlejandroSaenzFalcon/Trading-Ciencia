"""Error de circuit breaker abierto."""

from .base import IQOptionError


class IQOptionCircuitOpenError(IQOptionError):
    """Circuit breaker abierto - no se permiten requests."""

    def __init__(
        self,
        message: str = "Circuit breaker abierto",
        retry_after: float = 30.0,
        details: dict = None,
    ):
        super().__init__(message, "IQOPTION_CIRCUIT_OPEN", details)
        self.retry_after = retry_after
