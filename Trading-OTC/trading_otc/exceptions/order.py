"""Error en órdenes."""

from .base import IQOptionError


class IQOptionOrderError(IQOptionError):
    """Error en colocación/consulta de orden."""

    def __init__(self, message: str, order_id: str = None, details: dict = None):
        d = details or {}
        if order_id:
            d["order_id"] = order_id
        super().__init__(message, "IQOPTION_ORDER_ERROR", d)
