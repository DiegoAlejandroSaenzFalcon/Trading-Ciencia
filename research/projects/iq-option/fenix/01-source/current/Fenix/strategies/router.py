# ==========================================================
# [APEXQUANT] QUANTITATIVE REGIME ROUTER
# ==========================================================
# Determines the current market state (Regime) based on M1 
# microstructure physics and routes execution to the optimal strategy.
# ==========================================================

class RegimeRouter:
    def __init__(self):
        # Umbrales calibrados para Forex Real M1
        self.adx_trend_threshold = 25
        self.adx_flat_threshold = 20
        self.bb_squeeze_threshold = 0.0005
        self.bb_normal_threshold = 0.001
        self.roc_momentum_threshold = 0.05
        self.wick_toxic_threshold = 0.60

    def evaluate_regime(self, adx, bb_width, roc, wick_ratio):
        """
        Analiza los tensores matemáticos y devuelve el régimen dominante
        y la estrategia a la que se debe enrutar la señal.
        """
        # Seguridad: Si faltan datos críticos, bloqueamos la operativa
        if adx is None or bb_width is None or roc is None:
            return "UNKNOWN", "KILL_SWITCH"

        # 1. Filtro de Toxicidad (Algoritmo de Market Maker barriendo stops)
        if wick_ratio > self.wick_toxic_threshold and adx < self.adx_trend_threshold:
            return "TOXIC_CHOP", "KILL_SWITCH"

        # 2. Régimen de Compresión (Squeeze - Preparando explosión)
        if bb_width < self.bb_squeeze_threshold and adx < self.adx_flat_threshold:
            return "COMPRESSION", "STRATEGY_BREAKOUT"

        # 3. Régimen Tendencial (Fuerza y Dirección clara)
        if adx >= self.adx_trend_threshold and abs(roc) > self.roc_momentum_threshold:
            return "TRENDING", "STRATEGY_CONTINUITY"

        # 4. Régimen Lateral (Rebotes limpios entre soportes y resistencias)
        if adx < self.adx_flat_threshold and bb_width > self.bb_normal_threshold:
            return "RANGING", "STRATEGY_REVERSION"

        # 5. Zona Muerta (Transición entre regímenes, demasiado arriesgado)
        return "TRANSITION", "KILL_SWITCH"

# Instancia global para ser importada
market_router = RegimeRouter()