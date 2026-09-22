"""Error de validación."""

from .base import IQOptionError


class IQOptionValidationError(IQOptionError):
    """Validación de parámetros fallida (lado cliente)."""

    def __init__(self, message: str, field: str = None, details: dict = None):
        d = details or {}
        if field:
            d["field"] = field
        super().__init__(message, "IQOPTION_VALIDATION_ERROR", d)
