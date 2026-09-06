"""
Base Strategy Template — Interfaz común para todas las estrategias TSF.

Toda estrategia DEBE heredar de BaseStrategy e implementar los métodos abstractos.
Esto garantiza consistencia, trazabilidad y compatibilidad con el framework.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal, Optional, Any
import pandas as pd


@dataclass
class Signal:
    """
    Señal de trading con metadata completa para trazabilidad científica.

    Cada señal lleva toda la información necesaria para:
    - Reproducir la decisión exactamente
    - Auditar el proceso de investigación
    - Calcular métricas de calidad post-hoc
    """
    timestamp: datetime
    symbol: str
    direction: Literal["long", "short"]
    entry_price: float
    stop_loss: float
    take_profit: float
    size: float

    # Metadata para investigación (OBLIGATORIA)
    strategy_name: str
    strategy_version: str
    hypothesis_id: str
    indicators: dict = field(default_factory=dict)  # Valores de indicadores al momento
    regime: str = "unknown"                         # Contexto de mercado
    confidence: float = 0.0                         # 0-1, basado en validación histórica

    # Campos opcionales para ejecución
    order_type: str = "market"
    expiry: Optional[datetime] = None
    comment: str = ""

    def to_dict(self) -> dict:
        """Serializar a diccionario para logging/DB."""
        return {
            "timestamp": self.timestamp.isoformat(),
            "symbol": self.symbol,
            "direction": self.direction,
            "entry_price": self.entry_price,
            "stop_loss": self.stop_loss,
            "take_profit": self.take_profit,
            "size": self.size,
            "strategy_name": self.strategy_name,
            "strategy_version": self.strategy_version,
            "hypothesis_id": self.hypothesis_id,
            "indicators": self.indicators,
            "regime": self.regime,
            "confidence": self.confidence,
            "order_type": self.order_type,
            "expiry": self.expiry.isoformat() if self.expiry else None,
            "comment": self.comment,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Signal":
        """Deserializar desde diccionario."""
        return cls(
            timestamp=datetime.fromisoformat(data["timestamp"]),
            symbol=data["symbol"],
            direction=data["direction"],
            entry_price=data["entry_price"],
            stop_loss=data["stop_loss"],
            take_profit=data["take_profit"],
            size=data["size"],
            strategy_name=data["strategy_name"],
            strategy_version=data["strategy_version"],
            hypothesis_id=data["hypothesis_id"],
            indicators=data.get("indicators", {}),
            regime=data.get("regime", "unknown"),
            confidence=data.get("confidence", 0.0),
            order_type=data.get("order_type", "market"),
            expiry=datetime.fromisoformat(data["expiry"]) if data.get("expiry") else None,
            comment=data.get("comment", ""),
        )


class BaseStrategy(ABC):
    """
    Clase base abstracta para todas las estrategias TSF.

    Contrato:
    - calculate_indicators(): Vectorizado, determinista, sin side effects
    - generate_signals(): Usa solo datos disponibles en timestamp (no look-ahead)
    - get_required_history(): Barras mínimas para cálculos válidos
    - get_metadata(): Info para trazabilidad y reproducibilidad
    """

    name: str = "base"
    version: str = "0.1.0"
    hypothesis_id: str = ""

    def __init__(self, config: dict):
        self.config = config
        self._validate_config()

    @abstractmethod
    def _validate_config(self) -> None:
        """Validar configuración al instanciar. Debe lanzar AssertionError si inválida."""

    @abstractmethod
    def calculate_indicators(self, data: pd.DataFrame) -> pd.DataFrame:
        """
        Calcular indicadores sobre datos históricos completos.

        Args:
            data: DataFrame con columnas [open, high, low, close, volume], index=datetime UTC

        Returns:
            DataFrame con MISMAS filas + columnas de indicadores añadidas.

        Reglas:
        - DEBE ser determinista: misma entrada → misma salida siempre
        - DEBE ser vectorizado (no loops barra a barra)
        - NO debe modificar datos de entrada
        - Indicadores deben estar alineados temporalmente (misma index)
        """
        pass

    @abstractmethod
    def generate_signals(self, data: pd.DataFrame) -> list[Signal]:
        """
        Generar señales de trading para la última barra completada.

        Args:
            data: DataFrame YA PROCESADO por calculate_indicators()

        Returns:
            Lista de Signal objects (0, 1 o múltiples según lógica)

        Reglas CRÍTICAS (anti look-ahead):
        - Usar SOLO datos disponibles en timestamp de la barra
        - Para barra i, usar data.iloc[:i+1] (no data.iloc[i+1:])
        - Si usa barra previa para evitar repintado, usar i-1 explícitamente
        - NO acceder a datos futuros bajo NINGUNA circunstancia
        """
        pass

    @abstractmethod
    def get_required_history(self) -> int:
        """
        Número mínimo de barras históricas requeridas para cálculos válidos.

        Debe ser >= max(períodos de todos los indicadores) + buffer.
        """
        pass

    def get_metadata(self) -> dict:
        """Metadata para trazabilidad y reproducibilidad."""
        import hashlib
        import json

        config_str = json.dumps(self.config, sort_keys=True, default=str)
        config_hash = hashlib.sha256(config_str.encode()).hexdigest()[:16]

        return {
            "strategy_name": self.name,
            "strategy_version": self.version,
            "hypothesis_id": self.hypothesis_id,
            "config_hash": config_hash,
            "config": self.config,
            "required_history": self.get_required_history(),
        }

    # =========================================================================
    # HOOKS OPCIONALES (sobrescribir si necesario)
    # =========================================================================

    def on_init(self, context: dict) -> None:
        """Llamado una vez al inicializar (equivalente a OnInit en MQL5)."""
        pass

    def on_deinit(self, reason: int) -> None:
        """Llamado al desinicializar (equivalente a OnDeinit)."""
        pass

    def on_tick(self, tick_data: dict) -> None:
        """Llamado en cada tick (para estrategias tick-based)."""
        pass

    def on_trade_open(self, signal: Signal, fill_price: float, timestamp: datetime) -> None:
        """Llamado cuando se ejecuta una orden de entrada."""
        pass

    def on_trade_close(self, signal: Signal, exit_price: float, profit: float, timestamp: datetime) -> None:
        """Llamado cuando se cierra una posición (SL/TP/manual)."""
        pass

    def on_error(self, error: Exception, context: dict) -> None:
        """Llamado en error de ejecución."""
        pass


# ============================================================================
# REGISTRY PARA PLUGIN SYSTEM (Fase 6+)
# ============================================================================

_STRATEGY_REGISTRY: dict[str, type[BaseStrategy]] = {}


def register_strategy(cls: type[BaseStrategy]) -> type[BaseStrategy]:
    """Decorator para registrar estrategia en registry global."""
    if not issubclass(cls, BaseStrategy):
        raise TypeError(f"{cls.__name__} must inherit from BaseStrategy")
    if cls.name in _STRATEGY_REGISTRY:
        raise ValueError(f"Strategy name '{cls.name}' already registered")
    _STRATEGY_REGISTRY[cls.name] = cls
    return cls


def get_strategy(name: str) -> type[BaseStrategy]:
    """Obtener clase de estrategia por nombre."""
    if name not in _STRATEGY_REGISTRY:
        raise KeyError(f"Strategy '{name}' not registered. Available: {list(_STRATEGY_REGISTRY.keys())}")
    return _STRATEGY_REGISTRY[name]


def list_strategies() -> list[str]:
    """Listar estrategias registradas."""
    return list(_STRATEGY_REGISTRY.keys())


# ============================================================================
# EXAMPLE USAGE
# ============================================================================

if __name__ == "__main__":
    # Test básico de la interfaz
    print("BaseStrategy interface defined")
    print(f"Registered strategies: {list_strategies()}")