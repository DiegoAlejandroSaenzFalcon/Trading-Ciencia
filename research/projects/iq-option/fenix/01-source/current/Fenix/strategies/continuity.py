# ==========================================================
# [APEXQUANT] STRATEGY: STRUCTURAL CONTINUITY (M1)
# ==========================================================
# Philosophy: Exploits strong directional momentum (Trend Surfing).
# Ignores classic overbought/oversold levels. Enters on micro-pullbacks
# to dynamic value zones (EMA) while momentum is active.
# ==========================================================

class ContinuityStrategy:
    def __init__(self):
        # Safe Zones for RSI in a strong trend (Avoiding absolute exhaustion)
        self.rsi_call_min = 50
        self.rsi_call_max = 80
        self.rsi_put_min = 20
        self.rsi_put_max = 50

    def evaluate_signal(self, c_close, ema_short, rsi, roc, is_trend_up, is_trend_down):
        """
        Calcula la probabilidad de una continuación de tendencia.
        Retorna la acción ('call', 'put') y el ID de la sub-estrategia.
        """
        # Seguridad de datos
        if any(v is None for v in [ema_short, rsi, roc, is_trend_up, is_trend_down]):
            return None, None

        # 1. SURF ALCISTA (Buscando CALL)
        # Tendencia alcista validada, RSI fuerte pero no exhausto (>80 es peligroso), momentum positivo.
        # El precio se mantiene por encima de la EMA rápida (micro-pullback dinámico).
        if is_trend_up and self.rsi_call_min < rsi < self.rsi_call_max:
            if c_close > ema_short and roc > 0:
                return "call", "CONT-SURF-CALL"

        # 2. SURF BAJISTA (Buscando PUT)
        # Tendencia bajista validada, RSI bajo pero no exhausto (<20 es peligroso), momentum negativo.
        # El precio se mantiene por debajo de la EMA rápida.
        if is_trend_down and self.rsi_put_min < rsi < self.rsi_put_max:
            if c_close < ema_short and roc < 0:
                return "put", "CONT-SURF-PUT"

        return None, None

# Instancia global
continuity_module = ContinuityStrategy()