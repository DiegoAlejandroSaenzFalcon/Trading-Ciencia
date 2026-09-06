# Fase 0.2: Método Científico Aplicado al Trading

> **Duración: 3-4 horas**  
> **Objetivo: Entender por qué el método científico es la ÚNICA forma honesta de abordar el trading**

---

## El Problema: Ciencia vs Narrativa

```
NARRATIVA (Lo que hace el 99%):
├── "Esta estrategia funciona porque..."
├── Backtest bonito en un período
├── Ignora trades perdedores "excepcionales"
├── Cambia parámetros hasta que encaja
└── Resultado: Overfitting → Ruina en vivo

CIENCIA (Lo que HACEMOS aquí):
├── Hipótesis FALSABLE pre-registrada
├── Datos PIT (Point-in-Time) verificables
├── Validación CPCV honesta (DSR, PBO, MinTRL)
├── Gate fail-closed (factor-qc)
├── Adjudicación honesta (falsification-ledger)
└── Resultado: Evidencia real → Decisión informada
```

---

## El Ciclo Científico en Trading

```
┌─────────────────────────────────────────────────────────────────┐
│  1. OBSERVACIÓN                                                 │
│     "XAUUSD en M5 muestra patrones de reversión en sesión NY"  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. HIPÓTESIS FALSABLE (Pre-registro OBLIGATORIO)               │
│     "Kalman slope + EMA cross + ATR filter → +EV en XAUUSD M5" │
│     Kill criteria: DSR < 0.5, PBO > 0.05, MinTRL > datos       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. DISEÑO EXPERIMENTAL (Pipeline verificable)                  │
│     - Datos: OANDA raw → PIT rebuild (pit-adjuster)            │
│     - Pipeline: lf check (sin look-ahead)                      │
│     - Validación: CPCV N=12, K=6 (purgedcv)                    │
│     - n_trials HONESTO declarado                                │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. EJECUCIÓN Y RECOLECCIÓN DE EVIDENCIA                        │
│     - Backtest honesto → métricas OOS                           │
│     - factor-qc gate (fail-closed)                              │
│     - fl submit (evidencia independiente)                       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  5. ADJUDICACIÓN HONESTA (Una sola vez, inmutable)              │
│     - fl adjudicate: support / against / uncertain              │
│     - Si "against": HIPÓTESIS RECHAZADA. Punto.                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  6. REPORTES Y ITERACIÓN                                        │
│     - fl report: hit-rate vs baseline (Wilson 95% CI)           │
│     - Si baseline IN CI → "no systematic signal"                │
│     - Nueva hipótesis → vuelta al paso 2                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Conceptos Clave (Memoriza Estos)

### Hipótesis Falsable (Popper)
> **"Una afirmación es científica solo si algo podría contar en su contra."**

Ejemplos:
- ❌ "Esta estrategia es buena" → **No falsable**
- ❌ "Gana dinero en backtest" → **No falsable** (backtest ≠ realidad)
- ✅ "DSR > 0.5 con n_trials=247 en CPCV N=12/K=6" → **Falsable**
- ✅ "PBO < 0.05 en CSCV con 16 bloques" → **Falsable**

**Regla**: Si no puedes escribir **qué evidencia mataría tu hipótesis**, no es ciencia.

### Pre-Análisis Plan (Pre-registration)
> **Congelar expectativas ANTES de ver datos OOS.**

Beneficios (Olken 2015):
- Elimina p-hacking, data snooping, HARKing
- Fuerza claridad en kill criteria
- Crea pista de auditoría inmutable

Costos:
- No puedes "explorar" libremente (usa `source_type: exploratory` para eso)
- Verdicts "uncertain" son permitidos y honestos

### Evidencia Independiente
> **La evidencia debe venir de proceso INDEPENDIENTE del que generó la hipótesis.**

- Backtest del mismo código que generó la hipótesis → **NO independiente**
- CPCV con n_trials honesto → **Independiente**
- fl submit con reporte validado contra contrato → **Independiente**

---

## Los 4 Jinetes del Apocalipsis (Sesgos que Matan)

| Sesgo | Qué Es | Cómo Lo Matamos |
|-------|--------|-----------------|
| **Look-ahead Bias** | Usar datos futuros en decisión pasada | `lookahead-free` (DAG temporal verificable) |
| **Data Snooping** | Probar 1000 configs, reportar la mejor | `falsification-ledger` (pre-registro) + `factor-qc` (n_trials honesto) |
| **Survivorship Bias** | Backtest solo en símbolos que sobreviven | `pit-adjuster` + `ashare-data-immunity` (auditoría listing) |
| **Selection Bias** | Elegir métrica que se ve bien | `purgedcv` (DSR, PBO, MinTRL, Haircut) |

---

## Niveles de Evidencia (Jerarquía)

```
NIVEL 5 (Máximo): Live trading verificado ≥ 1 año, múltiples régimes
       │
NIVEL 4: Paper trading ≥ 6 meses + factor-qc PASS + fl adjudicated "support"
       │
NIVEL 3: CPCV honesto + DSR/PBO/MinTRL PASS + n_trials honesto
       │
NIVEL 2: Walk-forward honesto + métricas básicas
       │
NIVEL 1: Backtest simple (in-sample) → BASURA CIENTÍFICA
       │
NIVEL 0: "Funcionó en backtest" → NARRATIVA, NO CIENCIA
```

**En este framework: No pasas de Nivel 1 sin gates.**

---

## Tu Compromiso (Escríbelo)

> **Yo, [TU NOMBRE], me comprometo a:**
>
> 1. **Nunca** hacer backtest sin pre-registrar hipótesis
> 2. **Siempre** declarar `n_trials` honesto en factor-qc
> 3. **Aceptar** adjudicación "against" sin excusas
> 4. **Documentar** todo: datos, código, decisiones, errores
> 5. **No operar real** sin pasar gates Nivel 3+

---

## Ejercicio Práctico

Escribe tu **primera hipótesis falsable** para XAUUSD M5:

```json
{
  "hypothesis_id": "MI_PRIMERA_HIPOTESIS",
  "description": "ESCRIBE AQUÍ: Qué crees que funciona y por qué",
  "expected_direction": "long/short/neutral",
  "source_type": "pipeline",
  "falsification_contract": {
    "kill_criteria": [
      {"metric": "dsr", "threshold": 0.5, "operator": "<"},
      {"metric": "pbo", "threshold": 0.05, "operator": ">"},
      {"metric": "mintrl", "threshold": 1000, "operator": ">"}
    ]
  }
}
```

> **Guárdalo en `research/hypotheses/mi_primera_hipotesis.json`**
> **Luego: `tsf research preregister --hypothesis research/hypotheses/mi_primera_hipotesis.json`**

---

## Checklist Fase 0.2

- [ ] Entendido: narrativa ≠ ciencia en trading
- [ ] Entendido: 4 jinetes del apocalipsis y sus antídotos
- [ ] Entendido: jerarquía de evidencia (Nivel 0-5)
- [ ] Entendido: pre-registro es OBLIGATORIO, no opcional
- [ ] Entendido: adjudicación honesta duele pero es necesaria
- [ ] Primera hipótesis falsable escrita y guardada
- [ ] *Trading in the Zone* Cap. 1, 3, 7 leído

---

[Siguiente: Realidad del Riesgo →](03-risk-reality.md)