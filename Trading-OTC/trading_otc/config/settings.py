"""Configuración runtime del adapter IQ Option (no env, se inyecta)."""

from pydantic import BaseModel, Field


class IQOptionAdapterConfig(BaseModel):
    """Configuración del adapter IQ Option."""

    # Conexión
    ws_url: str = "wss://iqoption.com/echo/websocket"
    rest_url: str = "https://api.iqoption.com"
    email: str = ""
    password: str = ""
    demo: bool = True

    # Rate limiting
    rest_rps: int = Field(default=30, gt=0)
    ws_rps: int = Field(default=100, gt=0)

    # Resiliencia
    max_retries: int = Field(default=10, ge=0)
    base_backoff: float = Field(default=1.0, gt=0)
    max_backoff: float = Field(default=60.0, gt=0)
    cb_failure_threshold: int = Field(default=5, gt=0)
    cb_success_threshold: int = Field(default=3, gt=0)
    cb_timeout: float = Field(default=30.0, gt=0)

    # Timeouts
    connect_timeout: float = Field(default=10.0, gt=0)
    request_timeout: float = Field(default=5.0, gt=0)
    heartbeat_interval: float = Field(default=30.0, gt=0)

    # Reconciliación
    reconciliation_interval: float = Field(default=30.0, gt=0)
    order_ttl_seconds: int = Field(default=300, gt=0)

    # Idempotencia
    idempotency_ttl_seconds: int = Field(default=300, gt=0)
