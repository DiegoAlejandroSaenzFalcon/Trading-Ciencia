"""Error de conexión/red."""

from .base import IQOptionError


class IQOptionConnectionError(IQOptionError):
    """Error de red/WebSocket (timeout, disconnect, DNS, TLS)."""

    def __init__(self, message: str = "Error de conexión", details: dict = None):
        super().__init__(message, "IQOPTION_CONNECTION_ERROR", details)
