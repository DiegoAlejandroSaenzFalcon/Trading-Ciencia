"""
Configuración centralizada con Pydantic Settings.

Toda la configuración se carga desde variables de entorno (.env) con validación de tipos.
Nunca hardcodear secrets — usar .env (gitignored) y .env.example como template.
"""

from functools import lru_cache
from pathlib import Path
from typing import List, Literal, Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class OandaSettings(BaseSettings):
    """Configuración OANDA v20 API."""

    model_config = SettingsConfigDict(env_prefix="OANDA_")

    account_id: str = Field(default="", description="Account ID (demo o live)")
    api_key: str = Field(default="", description="API Key (Personal Access Token)")
    environment: Literal["practice", "live"] = "practice"
    streaming_host: str = "stream-fxpractice.oanda.com"
    rest_host: str = "api-fxpractice.oanda.com"

    @field_validator("streaming_host", "rest_host", mode="before")
    @classmethod
    def set_hosts_by_env(cls, v: str, info) -> str:
        if info.data.get("environment") == "live":
            return v.replace("fxpractice", "fxtrade")
        return v


class SymbolSettings(BaseSettings):
    """Configuración de símbolos y timeframes."""

    model_config = SettingsConfigDict(env_prefix="")

    default_symbol: str = "XAUUSD"
    default_timeframe: str = "M5"
    alternative_symbols: List[str] = ["BTCUSD", "EURUSD", "GBPUSD", "USDJPY"]
    session_start_hour: int = 13
    session_end_hour: int = 20


class DatabaseSettings(BaseSettings):
    """Configuración de base de datos."""

    model_config = SettingsConfigDict(env_prefix="")

    url: str = "sqlite+aiosqlite:///./data/tsf.db"


class RedisSettings(BaseSettings):
    """Configuración Redis (opcional)."""

    model_config = SettingsConfigDict(env_prefix="")

    url: str = "redis://localhost:6379/0"


class MonitoringSettings(BaseSettings):
    """Configuración de monitoreo y alertas."""

    model_config = SettingsConfigDict(env_prefix="")

    prometheus_port: int = 9090
    grafana_port: int = 3000
    grafana_admin_user: str = "admin"
    grafana_admin_password: str = "change-me-in-production"
    telegram_bot_token: Optional[str] = None
    telegram_chat_id: Optional[str] = None
    discord_webhook_url: Optional[str] = None


class GovernanceSettings(BaseSettings):
    """Configuración de gobernanza."""

    model_config = SettingsConfigDict(env_prefix="GOV_")

    policy_path: str = "governance/policy.yml"
    ledger_path: str = "governance/ledger.jsonl"
    require_human_approval: bool = True
    allow_live_trading: bool = False


class LoggingSettings(BaseSettings):
    """Configuración de logging."""

    model_config = SettingsConfigDict(env_prefix="LOG_")

    level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    format: Literal["json", "console"] = "json"
    file: str = "logs/tsf.log"


class BacktestSettings(BaseSettings):
    """Configuración de backtesting y validación."""

    model_config = SettingsConfigDict(env_prefix="DEFAULT_")

    n_splits: int = 12
    n_test_groups: int = 6
    periods_per_year: int = 252
    min_trials: int = 5


class ExecutionSettings(BaseSettings):
    """Configuración de ejecución y risk management (valores demo conservadores)."""

    model_config = SettingsConfigDict(env_prefix="DEFAULT_")

    sizing_mode: int = 2  # 0=fijo, 1=USD risk, 2=% equity
    risk_pct_equity: float = 0.5
    max_lots: float = 1.0
    sl_mult_atr: float = 1.5
    tp_r_multiple: float = 2.0
    cooldown_minutes: int = 10
    max_trades_per_day: int = 5
    daily_loss_limit_pct: float = 2.0


class KalmanSettings(BaseSettings):
    """Parámetros Kalman Filter (referencia histórica - no obligatorios)."""

    model_config = SettingsConfigDict(env_prefix="")

    bars: int = 50
    q: float = 0.05
    r: float = 0.30
    ema_period: int = 30
    signal_smoothing: int = 3


class VolatilitySettings(BaseSettings):
    """Filtros de volatilidad y spread."""

    model_config = SettingsConfigDict(env_prefix="")

    atr_period: int = 14
    min_vol_points: float = 50.0
    max_spread_pct_atr: float = 0.35


class MagicSettings(BaseSettings):
    """Magic number para identificación de órdenes."""

    model_config = SettingsConfigDict(env_prefix="")

    number: int = 482011


class Settings(BaseSettings):
    """Configuración principal que agrupa todas las sub-configuraciones."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Sub-configuraciones
    oanda: OandaSettings = Field(default_factory=OandaSettings)
    symbols: SymbolSettings = Field(default_factory=SymbolSettings)
    database: DatabaseSettings = Field(default_factory=DatabaseSettings)
    redis: RedisSettings = Field(default_factory=RedisSettings)
    monitoring: MonitoringSettings = Field(default_factory=MonitoringSettings)
    governance: GovernanceSettings = Field(default_factory=GovernanceSettings)
    logging: LoggingSettings = Field(default_factory=LoggingSettings)
    backtest: BacktestSettings = Field(default_factory=BacktestSettings)
    execution: ExecutionSettings = Field(default_factory=ExecutionSettings)
    kalman: KalmanSettings = Field(default_factory=KalmanSettings)
    volatility: VolatilitySettings = Field(default_factory=VolatilitySettings)
    magic: MagicSettings = Field(default_factory=MagicSettings)

    # Paths del proyecto
    project_root: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent)
    data_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "data")
    research_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "research")
    strategies_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "strategies")
    lessons_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "lessons")
    governance_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "governance")
    logs_dir: Path = Field(default_factory=lambda: Path(__file__).parent.parent.parent / "logs")

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        # Crear directorios si no existen
        for dir_path in [
            self.data_dir, self.research_dir, self.strategies_dir,
            self.lessons_dir, self.governance_dir, self.logs_dir,
            self.data_dir / "raw", self.data_dir / "pit",
            self.data_dir / "audits", self.data_dir / "manifests",
        ]:
            dir_path.mkdir(parents=True, exist_ok=True)


@lru_cache
def get_settings() -> Settings:
    """Singleton de configuración — cached para performance."""
    return Settings()


settings = get_settings()