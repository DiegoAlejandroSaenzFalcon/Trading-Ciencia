# Fase 0.3: Realidad del Riesgo â€” Drawdowns, Ruina, MatemÃ¡ticas

> **Duración: 2-3 horas**  
> **Objetivo: Internalizar las matemÃ¡ticas brutales que determinan si sobrevives**

---

## La MatemÃ¡tica que Nadie Te Cuenta

### 1. RecuperaciÃ³n de Drawdown (No Lineal)

| Drawdown | Ganancia Necesaria para Recuperar |
|----------|-----------------------------------|
| 5% | 5.3% |
| 10% | 11.1% |
| 20% | 25.0% |
| **25%** | **33.3%** |
| 30% | 42.9% |
| 40% | 66.7% |
| **50%** | **100%** |
| 60% | 150% |
| 70% | 233% |
| 80% | 400% |
| 90% | **900%** |

> **Regla**: Por encima de 20% drawdown, la recuperaciÃ³n se vuelve **exponencialmente difÃ­cil**.

### 2. Probabilidad de Ruina (Risk of Ruin)

FÃ³rmula de Kelly simplificada para trading discreto:

```python
def risk_of_ruin(win_rate: float, risk_reward: float, risk_per_trade: float, max_trades: int) -> float:
    """
    win_rate: 0.55 (55%)
    risk_reward: 2.0 (R:R 1:2)
    risk_per_trade: 0.02 (2%)
    max_trades: 1000
    """
    # Probabilidad de perder X trades seguidos que te arruinen
    # SimplificaciÃ³n: usar fÃ³rmula de Kelly fraccional
    kelly_f = win_rate - (1 - win_rate) / risk_reward  # f* = p - q/b
    optimal_risk = kelly_f / 2  # Half-Kelly para seguridad
    # Ruina â‰ˆ (1 - win_rate)^(capital / risk_per_trade)
    return (1 - win_rate) ** (1 / risk_per_trade)
```

**Tabla de Ruina (1000 trades, R:R 1:2):**

| Win Rate | Risk/Trade | Half-Kelly | P(Ruina) aprox |
|----------|------------|------------|----------------|
| 55% | 0.5% | 1.25% | ~0% |
| 55% | 1.0% | 1.25% | ~0% |
| 55% | **2.0%** | 1.25% | **~0.1%** |
| 55% | 5.0% | 1.25% | **~15%** |
| 50% | 2.0% | 0% | **~100%** |
| 45% | 2.0% | negativo | **100%** |

> **ConclusiÃ³n**: Con edge real (55% WR, 1:2 RR), **2% risk/trade es seguro**. Sin edge (50%), **cualquier risk > 0 te arruina eventualmente**.

### 3. La Ley de los Grandes NÃºmeros en Trading

```
N trades necesarios para que el resultado real â‰ˆ esperado:

Con edge pequeÃ±o (Sharpe 0.5):  N > 10,000 trades
Con edge medio  (Sharpe 1.0):  N > 2,500 trades
Con edge grande (Sharpe 2.0):  N >   600 trades
```

**En M5 (12 velas/hora Ã— 8h = 96 velas/dÃ­a):**
- 10 trades/dÃ­a â†’ 250 trades/mes â†’ 3,000 trades/aÃ±o
- **Necesitas ~1 aÃ±o de datos reales** para validar edge pequeÃ±o
- **Paper trading de 60 dÃ­as = ~600 trades = insuficiente para edge pequeÃ±o**

---

## Costes Estructurales (El Impuesto Invisible)

### XAUUSD en OANDA Demo (Valores TÃ­picos)

| Coste | Valor | Impacto Anual (10 trades/dÃ­a) |
|-------|-------|-------------------------------|
| Spread | 0.4-0.8 pips | $4,000-$8,000 |
| ComisiÃ³n | $0 (spread-only) | $0 |
| Slippage (normal) | 0.2-0.5 pips | $2,000-$5,000 |
| Slippage (noticias) | 5-20 pips | Variable |
| Swap (overnight) | Â±$0.5-2/lot/noche | $1,000-$4,000 |
| **TOTAL** | **0.6-1.3 pips/trade** | **$7,000-$17,000/aÃ±o** |

### Edge MÃ­nimo para Sobrevivir

```
Edge requerido > Costes totales / (Volatilidad Ã— Frecuencia)

XAUUSD M5: Volatilidad ~80 pips/dÃ­a, 10 trades/dÃ­a
Coste/trade: ~1 pip
Edge mÃ­nimo: 1 pip / (80 pips Ã— 10 trades) = 0.125% por trade
En R:R 1:2 â†’ Win rate mÃ­nimo = 33% + costes = ~35-36%
```

> **Si tu estrategia no tiene edge > 35% win rate neto de costes, matemÃ¡ticamente pierdes.**

---

## GestiÃ³n de Riesgo: Las 5 Reglas Inquebrantables

### Regla 1: Risk Per Trade Fijo (Nunca Variable)
```python
# CORRECTO
risk_per_trade = equity * 0.005  # 0.5% SIEMPRE
size = risk_per_trade / (entry - stop_loss)

# INCORRECTO (Gambler's fallacy)
if last_trade_won:
    risk_per_trade *= 1.5  # "Estoy en racha"
else:
    risk_per_trade *= 0.5  # "Recuperar pÃ©rdidas"
```

### Regla 2: Daily Loss Limit (Circuit Breaker)
```python
DAILY_LOSS_LIMIT = equity * 0.02  # 2% mÃ¡x por dÃ­a

if daily_pnl <= -DAILY_LOSS_LIMIT:
    STOP_TRADING_TODAY  # Sin excepciones
```
- Previene "revenge trading"
- Fuerza revisiÃ³n en frÃ­o
- Protege capital para maÃ±ana

### Regla 3: Cooldown Post-Loss
```python
COOLDOWN_MINUTES = 10  # MÃ­nimo tras trade perdedor

if last_trade_loss and (now - last_loss_time) < COOLDOWN_MINUTES:
    NO_NEW_TRADES
```
- Rompe espiral emocional
- Fuerza proceso cognitivo (System 2 thinking)

### Regla 4: Max Trades Per Day
```python
MAX_TRADES_PER_DAY = 5  # Calidad sobre cantidad

if trades_today >= MAX_TRADES_PER_DAY:
    NO_NEW_TRADES
```
- Previene overtrading
- Filtra solo mejores setups

### Regla 5: Position Sizing por Volatilidad (ATR)
```python
sl_distance = atr * SL_MULT_ATR  # ej: 1.5 Ã— ATR
tp_distance = sl_distance * TP_R_MULTIPLE  # ej: 2.0 Ã— SL
size = risk_per_trade / sl_distance

# LÃ­mites duros
size = max(min_lot, min(max_lot, size))
size = round(size / lot_step) * lot_step
```

---

## PsicologÃ­a del Riesgo (Por QuÃ© Fallas TÃº)

| Sesgo | ManifestaciÃ³n | AntÃ­doto SistemÃ¡tico |
|-------|---------------|---------------------|
| **Loss Aversion** | Cortar ganadores, dejar perdedores | SL/TP fijos, OCO obligatorio |
| **Overconfidence** | Aumentar size tras racha ganadora | Risk fijo % equity, max lots |
| **Recency Bias** | "Esta vez es diferente" | Pre-registro, gates, checklist |
| **Gambler's Fallacy** | "Ya perdÃ­ 3, toca ganar" | Cooldown, breaker, max trades |
| **Confirmation Bias** | Buscar solo seÃ±ales que confirman | Falsification-ledger kill criteria |
| **Sunk Cost** | "Ya perdÃ­ tanto, aguanto" | SL inamovible, sin averaging down |

---

## Tu Plan de Riesgo Personal (Completa Esto)

```yaml
# config/my_risk_plan.yaml
capital_inicial: 50000  # USD demo
risk_per_trade_pct: 0.5  # 0.5%
max_daily_loss_pct: 2.0  # 2%
max_drawdown_pct: 10.0   # 10% â†’ stop everything, review
cooldown_minutes: 10
max_trades_per_day: 5
max_concurrent_positions: 1
sl_mult_atr: 1.5
tp_r_multiple: 2.0
min_rrr: 1.5  # Risk:Reward mÃ­nimo aceptable
session_hours: "13:00-20:00"  # UTC
symbols_allowed: ["XAUUSD"]
timeframes_allowed: ["M5"]
```

> **GuÃ¡rdalo en `config/my_risk_plan.yaml` y compromÃ©tete a NO modificarlo en 30 dÃ­as.**

---

## SimulaciÃ³n Mental (Hazla Ahora)

Imagina esta secuencia:
1. Trade 1: Loss -$250 (0.5%)
2. Trade 2: Loss -$250 (1.0% total)
3. Trade 3: Loss -$250 (1.5% total)
4. Trade 4: Loss -$250 (2.0% total) â†’ **DAILY BREAKER ACTIVADO**
5. DÃ­a siguiente: 4 losses mÃ¡s â†’ 4% drawdown
6. Semana mala: 10% drawdown â†’ **MAX DRAWDOWN ALCANZADO**

**Preguntas:**
- Â¿Sigues tu plan o "recuperas"?
- Â¿Mueves SL "solo esta vez"?
- Â¿Aumentas size para "volver a cero"?
- Â¿Operas fuera de sesiÃ³n?

> **Si la respuesta a cualquiera es "sÃ­", no estÃ¡s listo para capital real.**

---

## Checklist Fase 0.3

- [ ] Entendido: matemÃ¡tica de recuperaciÃ³n de drawdown (no lineal)
- [ ] Entendido: probabilidad de ruina con/sin edge
- [ ] Entendido: ley de grandes nÃºmeros â†’ sample size requerido
- [ ] Calculado: costes estructurales reales para tu broker/sÃ­mbolo
- [ ] Entendido: edge mÃ­nimo para superar costes
- [ ] 5 reglas inquebrantables internalizadas
- [ ] Plan de riesgo personal escrito en `config/my_risk_plan.yaml`
- [ ] SimulaciÃ³n mental completada honestamente

---

[Siguiente: Fase 1 â€” Estructura de Mercado â†’](../ROADMAP.md)
