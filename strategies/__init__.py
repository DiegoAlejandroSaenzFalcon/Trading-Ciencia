"""
Strategies Package — Implementaciones de estrategias de trading.

Estructura:
- references/     : Estrategias de referencia histórica (KalmanATR, etc.)
- templates/      : Templates base (BaseStrategy)
- custom/         : Tus estrategias propias (crea aquí las tuyas)
"""

from .templates.base_strategy import (
    BaseStrategy,
    Signal,
    register_strategy,
    get_strategy,
    list_strategies,
)

__all__ = [
    "BaseStrategy",
    "Signal",
    "register_strategy",
    "get_strategy",
    "list_strategies",
]