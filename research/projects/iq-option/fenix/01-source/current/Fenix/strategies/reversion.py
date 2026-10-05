# ==========================================================
# [APEXQUANT] STRATEGY: MEAN REVERSION (M1)
# ==========================================================
# Philosophy: Exploits institutional profit-taking (elasticity) 
# when price deviates extremely from the mean in a ranging market.
# ==========================================================

class ReversionStrategy:
    def __init__(self):
        # Strict M1 Parameters for Forex Real
        self.rsi_overbought = 85  # Extremo absoluto
        self.rsi_oversold = 15
        self.min_wick_rejection = 0.30 # Mecha debe ser al menos 30% de la vela

    def evaluate_signal(self, c_close, c_open, upper_bb, lower_bb, rsi, rsi_diff, wick_upper, wick_lower):
        """
        Calcula la probabilidad de un snap-back.
        Retorna la acción ('call', 'put') y el ID de la sub-estrategia.
        """
        # Seguridad de datos
        if any(v is None for v in [upper_bb, lower_bb, rsi, rsi_diff]):
            return None, None

        # 1. LATIGAZO ALCISTA (Buscando PUT)
        # El precio rompe arriba, RSI extremo, pero el momentum colapsa y deja mecha.
        if c_close > upper_bb and rsi >= self.rsi_overbought:
            if rsi_diff < 0 and wick_upper > self.min_wick_rejection:
                return "put", "REV-SNAP-PUT"

        # 2. LATIGAZO BAJISTA (Buscando CALL)
        # El precio rompe abajo, RSI extremo, pero el momentum colapsa y deja mecha.
        if c_close < lower_bb and rsi <= self.rsi_oversold:
            if rsi_diff > 0 and wick_lower > self.min_wick_rejection:
                return "call", "REV-SNAP-CALL"

        return None, None

# Instancia global
reversion_module = ReversionStrategy()