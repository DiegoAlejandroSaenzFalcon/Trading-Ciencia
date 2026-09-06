# Fase 0.1: Qué es Trading Realmente

> **Duración: 2-3 horas de lectura + reflexión**  
> **Objetivo: Desmontar mitos, entender la naturaleza real del mercado**

---

## Lo Que NO Es Trading

| Mito | Realidad |
|------|----------|
| "Comprar bajo, vender alto" | Eso es **inversión pasiva** (buy & hold). Trading es **gestión activa de riesgo** |
| "Predecir el futuro" | **Imposible**. Trading es **asignar probabilidades** y gestionar resultados |
| "Ganar dinero rápido" | **Falacia del jugador**. El 90%+ pierde dinero el primer año |
| "Análisis técnico = bola de cristal" | TA es **lenguaje de acción del precio**, no predicción |
| "Más indicadores = mejor" | **Ruido**. Cada indicador añade lag y overfitting potencial |

---

## Lo Que SÍ Es Trading

### 1. Negocio de Probabilidades
```
Trading = Σ (Probabilidad × Payoff)  -  Costes  -  Slippage  -  Spread  -  Comisiones
```
- **Edge (ventaja)**: Pequeña asimetría estadística a tu favor (ej: 52% win rate, R:R 1:2)
- **Sample size**: Necesitas **cientos de trades** para que la ley de grandes números actúe
- **Variance**: En el corto plazo, **todo es ruido**. Rañas de 10-20 trades son normales

### 2. Gestión de Riesgo Profesional
```python
# La ÚNICA ecuación que importa
risk_per_trade = account_equity × risk_pct  # ej: $100k × 0.5% = $500
position_size = risk_per_trade / (entry - stop_loss)
```
- **Regla de oro**: Nunca arriesgar más del 1-2% por trade
- **Drawdown máximo**: Si pierdes 25%, necesitas 33% para recuperar. 50% → 100%. 90% → 900%
- **Ruin probability**: Con 2% risk/trade y 50% win rate, P(ruin) ≈ 0% en 1000 trades. Con 10% → ~100%

### 3. Juego de Suma Negativa (Para Retail)
```
Tu P&L = (Tu Edge × Volumen) - (Spread + Comisión + Slippage + Swap + Data + Infraestructura)
```
- **Spread + Comisión**: 0.5-2 pips por trade en XAUUSD = coste fijo
- **Slippage**: En noticias/volatilidad, 5-20 pips adicionales
- **Swap**: Mantener posiciones overnight cuesta (o paga) intereses
- **Infraestructura**: VPS, data feeds, tiempo = coste real

**Conclusión**: El mercado **te cobra por participar**. Tu edge debe superar **todos** los costes.

---

## Anatomía de un Trade

```
┌─────────────────────────────────────────────────────────────┐
│                    PRE-TRADE (Decisión)                     │
├─────────────────────────────────────────────────────────────┤
│  1. Hipótesis falsable                                      │
│  2. Contexto de mercado (régimen, volatilidad, sesión)      │
│  3. Setup: Entry, SL, TP, Size (pre-calculado)              │
│  4. Premortem: ¿Qué me haría NO entrar? (lesson-book match) │
│  5. Gates: factor-qc PASS, fl pre-registered, gov approved  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    DURANTE (Ejecución)                      │
├─────────────────────────────────────────────────────────────┤
│  1. Orden límite/mercado (nunca market en ilíquido)         │
│  2. OCO: SL + TP simultáneos (protección atómica)           │
│  3. Monitoreo: Breaker diario, cooldown, max trades/día     │
│  4. Psicología: Sin mover SL, sin añadir a perdedor         │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    POST-TRADE (Aprendizaje)                 │
├─────────────────────────────────────────────────────────────┤
│  1. Registro automático (DB + lesson-book)                  │
│  2. Si loss: ¿Por qué? → lb add (tuition memory)            │
│  3. Si win: ¿Fue suerte o edge? → No confundir              │
│  4. Revisión semanal: Patrones, coste total, ajustes        │
└─────────────────────────────────────────────────────────────┘
```

---

## Los Tres Pilares (Y Su Orden)

```
        ┌─────────────┐
        │  PSICOLOGÍA │  ←  FUNDAMENTAL (si fallas aquí, nada importa)
        └──────┬──────┘
               │
        ┌──────▼──────┐
        │ GESTIÓN     │  ←  ESTRUCTURAL (define si sobrevives)
        │ RIESGO      │
        └──────┬──────┘
               │
        ┌──────▼──────┐
        │ ESTRATEGIA  │  ←  OPERATIVA (edge estadístico)
        │ (EDGE)      │
        └─────────────┘
```

**Error fatal**: Empezar por "buscar estrategia" (el 99% de principiantes).

---

## Tu Primer Ejercicio (Obligatorio)

Antes de continuar, escribe en un papel (o `lessons/book.jsonl`):

1. **¿Por qué quieres hacer trading?** (Honestidad brutal)
2. **¿Cuánto capital puedes PERDER al 100% sin afectar tu vida?**
3. **¿Cuántas horas/semana puedes dedicar SERIAMENTE?**
4. **¿Cuál es tu horizonte temporal real?**
5. **Define tu "ruin point": ¿En qué drawdown dejas de operar?**

> **Si no puedes responder esto con números concretos, no estás listo para la Fase 1.**

---

## Lecturas Obligatorias (Antes de Fase 1)

| Libro | Por Qué | Capítulos Clave |
|-------|---------|-----------------|
| **Trading in the Zone** — Mark Douglas | Psicología, probabilidad, disciplina | 1, 3, 7 |
| **The Checklist Manifesto** — Atul Gawande | Checklists reducen errores 10x | Todos |
| **Fooled by Randomness** — Nassim Taleb | Ruido vs señal, survivorship bias | 1, 3, 11 |
| **Advances in Financial ML** — Marcos López de Prado | Fundamentos matemáticos rigorosos | 1, 4, 7, 12 |

---

## Reflexión Final

> **"El trading no es sobre tener razón. Es sobre ganar dinero cuando tienes razón y perder poco cuando te equivocas."** — George Soros

> **"Los amateurs piensan en cuánto pueden ganar. Los profesionales piensan en cuánto pueden perder."** — Paul Tudor Jones

---

## Checklist Fase 0.1

- [ ] Leído completo este documento
- [ ] Ejercicio de 5 preguntas completado por escrito
- [ ] Entendido: trading = gestión de riesgo + probabilidades, NO predicción
- [ ] Entendido: costes estructurales (spread, slippage, swap) comen edge
- [ ] Entendido: psicología es el pilar fundamental
- [ ] Libro *Trading in the Zone* pedido/empezado

---

[Siguiente: Método Científico Aplicado →](02-scientific-method.md)