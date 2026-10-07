# ==========================================================
# [APEXQUANT] STRATEGY: BREAKOUT MOMENTUM (M1)
# ==========================================================
# Philosophy: Exploits volatility expansion from a compression 
# zone (Bollinger Squeeze). Triggers on the first explosive 
# candle that breaks the band with confirmed momentum.
# ==========================================================

class BreakoutStrategy:
    def __init__(self):
        # Strict thresholds to filter out false breakouts (Fake-outs)
        self.min_candle_explosion = 0.015 # % mínimo de expansión del cuerpo
        self.min_roc_explosion = 0.02     # Explosión de momentum

    def evaluate_signal(self, c_close, c_open, upper_bb, lower_bb, roc, rsi_diff, candle_size):
        """
        Calcula la probabilidad de una ruptura institucional.
        Retorna la acción ('call', 'put') y el ID de la sub-estrategia.
        """
        # Seguridad de datos
        if any(v is None for v in [upper_bb, lower_bb, roc, rsi_diff, candle_size]):
            return None, None

        # 1. RUPTURA ALCISTA (Buscando CALL)
        # El precio rompe la banda superior con una vela sólida (sin mecha de rechazo fuerte) y momentum explosivo.
        if c_close > upper_bb and candle_size > self.min_candle_explosion:
            if roc > self.min_roc_explosion and rsi_diff > 0:
                return "call", "BRK-EXP-CALL"

        # 2. RUPTURA BAJISTA (Buscando PUT)
        # El precio rompe la banda inferior con vela sólida y caída abrupta de momentum.
        if c_close < lower_bb and candle_size > self.min_candle_explosion:
            if roc < -self.min_roc_explosion and rsi_diff < 0:
                return "put", "BRK-EXP-PUT"

        return None, None

# Instancia global
breakout_module = BreakoutStrategy()