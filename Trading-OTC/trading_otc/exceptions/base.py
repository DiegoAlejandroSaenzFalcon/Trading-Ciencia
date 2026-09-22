"""Excepción base para IQ Option."""


class IQOptionError(Exception):
    """Base exception."""

    def __init__(self, message: str, code: str = "IQOPTION_ERROR", details: dict = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}
