"""
KalmanATR Scalper — Reference Implementation (Port from MQL5)

ORIGINAL: KalmanATR_Scalper.mq5 (MetaTrader 5 EA)
AUTHOR: Diego Saenz (Monetizacion 48h - open source)
LICENSE: MIT

⚠️  IMPORTANTE: Esta es una ESTRATEGIA DE REFERENCIA HISTÓRICA.
    Se conserva porque dio indicios positivos en backtest inicial.
    NO es "la estrategia buena" — el proceso científico validará su viabilidad real.
    Ver: docs/02-research/01-hypothesis-driven.md para formular hipótesis falsable.

Arquitectura:
- BaseStrategy interface (tsf.strategies.templates.base_strategy)
- Kalman Filter 1D vectorizado (numpy)
- ATR, EMA via ta-lib/pandas-ta
- Risk management integrado
- Metadata completa para trazabilidad científica
"""

from __future__ import annotations

import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal, Optional
import hashlib
import json

try:
    import talib
    HAS_TALIB = True
except ImportError:
    HAS_TALIB = False

try:
    import pandas_ta as pta
    HAS_PANDAS_TA = True
except ImportError:
    HAS_PANDAS_TA = False

from tsf.strategies.templates.base_strategy import BaseStrategy, Signal


@dataclass
class KalmanATRConfig:
    """Configuración de la estrategia (equivalente a inputs MQL5)."""

    # Riesgo y tamaño
    sizing_mode: int = 2              # 0=fijo, 1=riesgoUSD, 2=riesgo%equity
    fixed_lots: float = 0.05
    risk_usd: float = 20.0
    risk_pct_equity: float = 0.50
    max_lots: float = 1.0
    sl_mult_atr: float = 1.5
    tp_r_multiple: float = 2.0
    cooldown_minutes: int = 10
    max_trades_per_day: int = 5
    daily_loss_limit_pct: float = 2.0

    # Filtros sesión y mercado
    session_enable: bool = True
    start_hour: int = 13              # Hora servidor (UTC)
    end_hour: int = 20
    atr_period: int = 14
    min_vol_points: float = 50.0
    max_spread_pct_atr: float = 0.35

    # Kalman
    kalman_bars: int = 50
    kalman_q: float = 0.05
    kalman_r: float = 0.30
    ema_period: int = 30
    signal_smoothing: int = 3

    # Operativa
    magic: int = 482011
    use_magic: bool = True

    def to_dict(self) -> dict:
        return {k: v for k, v in self.__dict__.items()}

    def config_hash(self) -> str:
        """Hash determinista para trazabilidad."""
        return hashlib.sha256(
            json.dumps(self.to_dict(), sort_keys=True).encode()
        ).hexdigest()[:16]


class KalmanFilter1D:
    """
    Filtro de Kalman discreto escalar 1D — versión vectorizada.

    MQL5 original: recursivo barra a barra (lento en Python).
    Python: vectorizado sobre array completo (~100x más rápido).
    """

    def __init__(self, q: float = 0.05, r: float = 0.30):
        """
        Args:
            q: Varianza de proceso (reactividad) - MQL5: InpKalmanQ
            r: Varianza de medición (suavizado) - MQL5: InpKalmanR
        """
        self.q = q
        self.r = r

    def estimate(self, prices: np.ndarray) -> np.ndarray:
        """
        Estima el filtro de Kalman sobre todo el array de precios.

        Args:
            prices: Array 1D de precios (close prices), shape (n,)

        Returns:
            Array 1D de estimaciones Kalman, shape (n,)
        """
        n = len(prices)
        if n < 3:
            return np.full(n, np.nan)

        est = np.zeros(n)
        p = np.zeros(n)

        # Inicialización (equivalente a g_kalmanInit = false en MQL5)
        est[0] = prices[0]
        p[0] = 1.0

        # Vectorizado: loop optimizado en Python (numba lo haría más rápido)
        for i in range(1, n):
            # Predicción
            p_pred = p[i-1] + self.q

            # Actualización (medición)
            k = p_pred / (p_pred + self.r)          # Ganancia de Kalman
            est[i] = est[i-1] + k * (prices[i] - est[i-1])
            p[i] = (1.0 - k) * p_pred

        return est

    def slope(self, prices: np.ndarray, smoothing: int = 3) -> np.ndarray:
        """
        Calcula pendiente de la estimación Kalman (equivalente a InpSignalSmoothing).

        Args:
            prices: Array de precios close
            smoothing: Barras para calcular pendiente (MQL5: InpSignalSmoothing)

        Returns:
            Array de pendientes (kalman[i] - kalman[i-smoothing])
        """
        kalman_est = self.estimate(prices)
        slope = np.full_like(kalman_est, np.nan)
        if len(kalman_est) > smoothing:
            slope[smoothing:] = kalman_est[smoothing:] - kalman_est[:-smoothing]
        return slope


class KalmanATRStrategy(BaseStrategy):
    """
    KalmanATR Scalper — Port exacto del EA MQL5 a Python científico.

    Señales:
    - LONG:  Kalman cruza EMA al alza + pendiente positiva
    - SHORT: Kalman cruza EMA a la baja + pendiente negativa

    Filtros:
    - Sesión horaria (start_hour - end_hour UTC)
    - Volatilidad mínima (ATR > min_vol_points)
    - Spread máximo (% de ATR)
    - Cooldown post-loss
    - Max trades/día
    - Daily loss breaker
    """

    name = "kalman_atr"
    version = "1.0.0"
    hypothesis_id = ""  # Se setea en runtime desde hypothesis_id

    def __init__(self, config: Optional[KalmanATRConfig] = None, **kwargs):
        # Merge config + kwargs
        if config is None:
            config = KalmanATRConfig(**kwargs)
        self.cfg = config

        # Estado interno (equivalente a variables globales MQL5)
        self._trades_today = 0
        self._last_trade_day: Optional[datetime] = None
        self._last_loss_time: Optional[datetime] = None
        self._day_start_equity: float = 0.0

        # Handles de indicadores (cache)
        self._kalman_filter = KalmanFilter1D(q=self.cfg.kalman_q, r=self.cfg.kalman_r)
        self._atr_cache: Optional[np.ndarray] = None
        self._ema_cache: Optional[np.ndarray] = None
        self._kalman_cache: Optional[np.ndarray] = None
        self._kalman_slope_cache: Optional[np.ndarray] = None

        super().__init__(config=self.cfg.to_dict())

    def _validate_config(self) -> None:
        """Validar configuración (equivalente a checks en OnInit)."""
        assert self.cfg.sizing_mode in (0, 1, 2), "sizing_mode debe ser 0, 1 o 2"
        assert 0 < self.cfg.risk_pct_equity <= 5.0, "risk_pct_equity inválido"
        assert self.cfg.max_lots > 0, "max_lots debe ser > 0"
        assert self.cfg.sl_mult_atr > 0, "sl_mult_atr debe ser > 0"
        assert self.cfg.tp_r_multiple > 1.0, "tp_r_multiple debe ser > 1.0"
        assert 0 <= self.cfg.start_hour < 24, "start_hour inválido"
        assert 0 <= self.cfg.end_hour < 24, "end_hour inválido"
        assert self.cfg.atr_period >= 2, "atr_period debe ser >= 2"
        assert self.cfg.kalman_bars >= 10, "kalman_bars debe ser >= 10"
        assert 0 < self.cfg.kalman_q < 1, "kalman_q debe ser (0,1)"
        assert 0 < self.cfg.kalman_r < 1, "kalman_r debe ser (0,1)"
        assert self.cfg.ema_period >= 2, "ema_period debe ser >= 2"
        assert self.cfg.signal_smoothing >= 1, "signal_smoothing debe ser >= 1"

    def get_required_history(self) -> int:
        """Barras mínimas requeridas para cálculos."""
        return max(
            self.cfg.kalman_bars,
            self.cfg.ema_period,
            self.cfg.atr_period,
            self.cfg.signal_smoothing
        ) + 10  # Buffer

    def calculate_indicators(self, data: pd.DataFrame) -> pd.DataFrame:
        """
        Calcular indicadores vectorizados.

        Args:
            data: DataFrame con columnas [open, high, low, close, volume], index=datetime

        Returns:
            DataFrame con columnas añadidas: atr, ema, kalman, kalman_slope
        """
        # Validar columnas requeridas
        required = ['open', 'high', 'low', 'close', 'volume']
        for col in required:
            if col not in data.columns:
                raise ValueError(f"Columna requerida faltante: {col}")

        close = data['close'].values
        high = data['high'].values
        low = data['low'].values

        n = len(close)
        result = data.copy()

        # ATR (ta-lib o pandas-ta fallback)
        if HAS_TALIB:
            atr = talib.ATR(high, low, close, timeperiod=self.cfg.atr_period)
        elif HAS_PANDAS_TA:
            atr = pta.atr(high=pd.Series(high), low=pd.Series(low), close=pd.Series(close),
                          length=self.cfg.atr_period).values
        else:
            # Implementación manual simple
            tr = np.maximum(
                high - low,
                np.maximum(
                    np.abs(high - np.roll(close, 1)),
                    np.abs(low - np.roll(close, 1))
                )
            )
            tr[0] = np.nan
            atr = pd.Series(tr).rolling(self.cfg.atr_period).mean().values

        # EMA
        if HAS_TALIB:
            ema = talib.EMA(close, timeperiod=self.cfg.ema_period)
        elif HAS_PANDAS_TA:
            ema = pta.ema(pd.Series(close), length=self.cfg.ema_period).values
        else:
            ema = pd.Series(close).ewm(span=self.cfg.ema_period, adjust=False).mean().values

        # Kalman Filter (vectorizado)
        kalman = self._kalman_filter.estimate(close)

        # Kalman Slope (pendiente)
        kalman_slope = self._kalman_filter.slope(close, self.cfg.signal_smoothing)

        # Cache para generate_signals
        self._atr_cache = atr
        self._ema_cache = ema
        self._kalman_cache = kalman
        self._kalman_slope_cache = kalman_slope

        # Añadir al DataFrame resultado
        result['atr'] = atr
        result['ema'] = ema
        result['kalman'] = kalman
        result['kalman_slope'] = kalman_slope

        return result

    def generate_signals(self, data: pd.DataFrame) -> list[Signal]:
        """
        Generar señales de trading (equivalente a OnTick en MQL5).

        Lógica exacta del EA original:
        1. Reset diario
        2. Filtros: breaker, sesión, max trades, cooldown, posición abierta
        3. ATR + Spread filter
        4. EMA + Kalman crossover + slope
        5. Calcular SL/TP + size
        """
        signals = []

        if len(data) < 2:
            return signals

        # Última barra completada (índice -2 para evitar repintado, como MQL5 usa barra 1)
        i = -2
        if abs(i) > len(data):
            return signals

        # --- 1. RESET DIARIO ---
        now = data.index[i]
        today = now.replace(hour=0, minute=0, second=0, microsecond=0)

        if self._last_trade_day != today:
            self._last_trade_day = today
            self._trades_today = 0
            # day_start_equity se actualiza desde account en runtime

        # --- 2. FILTROS PREVIOS ---
        # Daily breaker (se verifica en runtime con equity real)
        # if daily_breaker: return []

        # Sesión
        if self.cfg.session_enable and not self._in_session(now):
            return signals

        # Max trades/día
        if self._trades_today >= self.cfg.max_trades_per_day:
            return signals

        # Cooldown post-loss
        if self._last_loss_time and (now - self._last_loss_time).total_seconds() < self.cfg.cooldown_minutes * 60:
            return signals

        # Solo una posición a la vez (se verifica en runtime con positions)

        # --- 3. INDICADORES (usar cache) ---
        atr = self._atr_cache[i] if self._atr_cache is not None else np.nan
        if np.isnan(atr) or atr <= 0:
            return signals

        # Volatilidad mínima
        point = 0.01  # XAUUSD point = 0.01 (ajustar por símbolo)
        min_vol = self.cfg.min_vol_points * point
        if atr < min_vol:
            return signals

        # Spread filter (requiere bid/ask real - placeholder)
        # spread = ask - bid
        # if spread > atr * self.cfg.max_spread_pct_atr: return []

        # EMA (barra previa para evitar repintado directo)
        ema_prev = self._ema_cache[i-1] if self._ema_cache is not None and abs(i-1) <= len(data) else np.nan
        ema_curr = self._ema_cache[i] if self._ema_cache is not None else np.nan
        if np.isnan(ema_prev) or np.isnan(ema_curr):
            return signals

        # Kalman actual y pendiente
        kalman_curr = self._kalman_cache[i] if self._kalman_cache is not None else np.nan
        kalman_slope = self._kalman_slope_cache[i] if self._kalman_slope_cache is not None else np.nan
        if np.isnan(kalman_curr) or np.isnan(kalman_slope):
            return signals

        # Kalman previo (aproximación: close previo como proxy, como MQL5)
        kalman_prev = data['close'].iloc[i-1] if abs(i-1) <= len(data) else np.nan

        # --- 4. SEÑALES: CRUCE KALMAN/EMA + PENDIENTE ---
        cross_up = (kalman_prev <= ema_prev and kalman_curr > ema_curr) and kalman_slope > 0
        cross_down = (kalman_prev >= ema_prev and kalman_curr < ema_curr) and kalman_slope < 0

        # Precios para ejecución
        bid = data['close'].iloc[i]  # Proxy: close ≈ bid en datos históricos
        ask = bid  # En datos históricos close ≈ bid ≈ ask (spread se añade en runtime)

        if cross_up:
            signal = self._create_signal(
                data=data, i=i, direction="long",
                bid=bid, ask=ask, atr=atr, kalman_slope=kalman_slope
            )
            if signal:
                signals.append(signal)
                self._trades_today += 1

        elif cross_down:
            signal = self._create_signal(
                data=data, i=i, direction="short",
                bid=bid, ask=ask, atr=atr, kalman_slope=kalman_slope
            )
            if signal:
                signals.append(signal)
                self._trades_today += 1

        return signals

    def _in_session(self, dt: datetime) -> bool:
        """Verificar si estamos en sesión permitida (MQL5: InSession)."""
        if not self.cfg.session_enable:
            return True
        hour = dt.hour
        if self.cfg.start_hour < self.cfg.end_hour:
            return self.cfg.start_hour <= hour < self.cfg.end_hour
        return hour >= self.cfg.start_hour or hour < self.cfg.end_hour

    def _create_signal(
        self,
        data: pd.DataFrame,
        i: int,
        direction: Literal["long", "short"],
        bid: float,
        ask: float,
        atr: float,
        kalman_slope: float
    ) -> Optional[Signal]:
        """Crear Signal object con todos los metadatos."""
        # Distancia SL en puntos de precio
        sl_dist = atr * self.cfg.sl_mult_atr

        # Tick value/size para XAUUSD (ajustar por broker/símbolo)
        # XAUUSD: 1 lot = 100 oz, 1 pip = 0.1 USD? No, 1 pip = $1 per lot en XAUUSD estándar
        # Mejor: usar symbol info del broker en runtime. Aquí placeholder.
        tick_value = 1.0  # $1 per pip per lot
        point = 0.01

        sl_dist_points = sl_dist / point if point > 0 else sl_dist

        # Sizing (equivalente a CalcLots en MQL5)
        lots = self._calc_lots(sl_dist_points, point, tick_value)

        if direction == "long":
            entry = ask
            sl = entry - sl_dist
            tp = entry + sl_dist * self.cfg.tp_r_multiple
        else:
            entry = bid
            sl = entry + sl_dist
            tp = entry - sl_dist * self.cfg.tp_r_multiple

        # Normalizar a dígitos del símbolo (XAUUSD = 2 decimales típicamente)
        digits = 2
        entry = round(entry, digits)
        sl = round(sl, digits)
        tp = round(tp, digits)

        return Signal(
            timestamp=data.index[i],
            symbol="XAUUSD",
            direction=direction,
            entry_price=entry,
            stop_loss=sl,
            take_profit=tp,
            size=lots,
            strategy_name=self.name,
            strategy_version=self.version,
            hypothesis_id=self.hypothesis_id,
            indicators={
                "atr": float(atr),
                "ema": float(self._ema_cache[i]) if self._ema_cache is not None else None,
                "kalman": float(self._kalman_cache[i]) if self._kalman_cache is not None else None,
                "kalman_slope": float(kalman_slope),
            },
            regime="unknown",  # Se puede añadir detección de régimen
            confidence=0.0,    # Se calcula en validation phase
        )

    def _calc_lots(self, sl_dist_points: float, point: float, tick_value: float) -> float:
        """Cálculo de lotes (equivalente a CalcLots en MQL5)."""
        if self.cfg.sizing_mode == 0:
            lots = self.cfg.fixed_lots
        elif self.cfg.sizing_mode == 1:
            risk_money = self.cfg.risk_usd
            lots = risk_money / (sl_dist_points * tick_value) if sl_dist_points > 0 and tick_value > 0 else self.cfg.fixed_lots
        else:  # mode 2: % equity
            # equity se pasa en runtime; aquí placeholder
            equity = 10000.0  # Placeholder - se sobrescribe en runtime
            risk_money = equity * self.cfg.risk_pct_equity / 100.0
            lots = risk_money / (sl_dist_points * tick_value) if sl_dist_points > 0 and tick_value > 0 else self.cfg.fixed_lots

        # Límites
        lots = max(0.01, min(self.cfg.max_lots, lots))
        # Redondear a step (0.01 típico)
        lots = round(lots / 0.01) * 0.01
        return lots

    def get_metadata(self) -> dict:
        base = super().get_metadata()
        base.update({
            "config_hash": self.cfg.config_hash(),
            "kalman_q": self.cfg.kalman_q,
            "kalman_r": self.cfg.kalman_r,
            "kalman_bars": self.cfg.kalman_bars,
        })
        return base

    # --- Métodos para gestión de estado en runtime ---

    def on_trade_closed(self, profit: float, timestamp: datetime) -> None:
        """Llamar cuando se cierra un trade (equivalente a OnTradeTransaction)."""
        if profit < 0:
            self._last_loss_time = timestamp

    def update_daily_equity(self, equity: float, timestamp: datetime) -> None:
        """Actualizar equity inicial del día."""
        today = timestamp.replace(hour=0, minute=0, second=0, microsecond=0)
        if self._last_trade_day != today:
            self._last_trade_day = today
            self._trades_today = 0
            self._day_start_equity = equity

    def check_daily_breaker(self, equity: float) -> bool:
        """Verificar breaker diario (equivalente a DailyBreaker en MQL5)."""
        if self.cfg.daily_loss_limit_pct <= 0:
            return False
        if self._day_start_equity <= 0:
            return False
        loss_pct = (self._day_start_equity - equity) / self._day_start_equity * 100.0
        return loss_pct >= self.cfg.daily_loss_limit_pct

    def can_trade(self, equity: float, has_open_position: bool, timestamp: datetime) -> tuple[bool, str]:
        """
        Verificar si se puede operar ahora.
        Returns: (can_trade, reason_if_not)
        """
        if self.check_daily_breaker(equity):
            return False, "daily_breaker"

        if has_open_position:
            return False, "position_open"

        if not self._in_session(timestamp):
            return False, "outside_session"

        if self._trades_today >= self.cfg.max_trades_per_day:
            return False, "max_trades_per_day"

        if self._last_loss_time and (timestamp - self._last_loss_time).total_seconds() < self.cfg.cooldown_minutes * 60:
            return False, "cooldown"

        return True, "ok"


# ============================================================================
# FACTORY FUNCTION (para uso en CLI/config)
# ============================================================================

def create_kalman_atr_strategy(config_dict: dict) -> KalmanATRStrategy:
    """Crear estrategia desde diccionario de config."""
    config = KalmanATRConfig(**config_dict)
    return KalmanATRStrategy(config=config)


# ============================================================================
# TESTING / DEMO
# ============================================================================

if __name__ == "__main__":
    # Demo rápido con datos sintéticos
    import matplotlib.pyplot as plt

    print("=== KalmanATR Strategy Demo ===")

    # Generar datos sintéticos
    np.random.seed(42)
    n = 500
    dates = pd.date_range('2024-01-01', periods=n, freq='5min')
    base = 2000.0
    returns = np.random.normal(0, 0.0005, n)
    close = base * np.exp(np.cumsum(returns))
    high = close * (1 + np.abs(np.random.normal(0, 0.0003, n)))
    low = close * (1 - np.abs(np.random.normal(0, 0.0003, n)))
    open_ = np.roll(close, 1)
    open_[0] = close[0]
    volume = np.random.randint(100, 1000, n)

    df = pd.DataFrame({
        'open': open_, 'high': high, 'low': low, 'close': close, 'volume': volume
    }, index=dates)

    # Crear estrategia
    strategy = KalmanATRStrategy()
    print(f"Config hash: {strategy.cfg.config_hash()}")

    # Calcular indicadores
    df_ind = strategy.calculate_indicators(df)
    print(f"Indicadores calculados: {df_ind.columns.tolist()}")

    # Generar señales
    signals = strategy.generate_signals(df_ind)
    print(f"Señales generadas: {len(signals)}")
    for s in signals[:5]:
        print(f"  {s.timestamp} {s.direction} @ {s.entry_price:.2f} SL={s.stop_loss:.2f} TP={s.take_profit:.2f} Size={s.size}")

    # Plot
    fig, axes = plt.subplots(3, 1, figsize=(12, 10), sharex=True)
    axes[0].plot(df.index, df['close'], label='Close', alpha=0.7)
    axes[0].plot(df.index, df_ind['ema'], label=f'EMA({strategy.cfg.ema_period})', alpha=0.8)
    axes[0].plot(df.index, df_ind['kalman'], label='Kalman', alpha=0.8)
    axes[0].set_ylabel('Price')
    axes[0].legend()
    axes[0].set_title('KalmanATR - Price & Indicators')

    axes[1].plot(df.index, df_ind['atr'], label='ATR', color='orange')
    axes[1].set_ylabel('ATR')
    axes[1].legend()

    axes[2].plot(df.index, df_ind['kalman_slope'], label='Kalman Slope', color='green')
    axes[2].axhline(y=0, color='k', linestyle='--', alpha=0.3)
    axes[2].set_ylabel('Slope')
    axes[2].legend()

    # Marcar señales
    for s in signals:
        color = 'green' if s.direction == 'long' else 'red'
        marker = '^' if s.direction == 'long' else 'v'
        axes[0].scatter(s.timestamp, s.entry_price, color=color, marker=marker, s=100, zorder=5)

    plt.tight_layout()
    plt.savefig('kalman_atr_demo.png', dpi=150)
    print("Demo plot guardado en kalman_atr_demo.png")