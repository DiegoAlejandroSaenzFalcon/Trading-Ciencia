"""Error de autenticación."""

from .base import IQOptionError


class IQOptionAuthError(IQOptionError):
    """Fallo de autenticación (credenciales inválidas, 2FA, etc.)."""

    def __init__(self, message: str = "Autenticación fallida", details: dict = None):
        super().__init__(message, "IQOPTION_AUTH_ERROR", details)
