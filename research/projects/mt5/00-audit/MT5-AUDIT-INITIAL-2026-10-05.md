# Auditoría forense inicial — MT5 / MQL5

**Fecha:** 2026-10-05  
**Alcance:** `C:\Users\Diego Saenz\OneDrive\Diego\Experts`  
**Destino de investigación:** `C:\Proyectos\Trading-Ciencia\research\projects\mt5`  
**Método:** inventario recursivo, SHA-256, metadatos, análisis estático de fuentes, separación de terceros y reconstrucción de genealogía.

## 1. Resultado ejecutivo

La colección contiene un historial amplio y valioso de desarrollo MQL5. Se confirma que no es un único EA: contiene familias ApexQuant, NeurAlgo, Fenix/variantes, Trendsniper, Quantum Queen, Akali, Oro/Gold, Satoshi, SMC/breakout, Engulfing y utilidades/diagnóstico, además de material de terceros.

La estrategia correcta es **preservar primero, clasificar segundo y rediseñar tercero**. No se deben sobrescribir históricos para “mejorarlos”.

## 2. Inventario

| Métrica | Resultado |
|---|---:|
| Archivos analizados | 186 |
| .mq5 | 93 |
| .mqh | 3 |
| .ex5 | 90 |
| .mq5 sin .ex5 | 5 |
| .ex5 sin .mq5 | 2 |
| Fuentes propias/desconocidas | 104 archivos totales |
| Terceros/referencia | 82 archivos totales |

Las cifras anteriores incluyen material de referencia. La separación detallada está en `MT5-FULL-INVENTORY.csv/json`.

## 3. Fuentes sin correspondencia de compilado

### MQ5 sin EX5

- `ApexQuant_V7.8-PRO.mq5`
- `Core_Sensor.mqh.mq5`
- `Multi.mq5`
- `NeurAlgo.mq5`
- `NeurAlgo_Gold_V1.mq5`

### EX5 sin MQ5

- `BTCUSD NeurAlgo M15.ex5`
- `Market\XAUUSD 5 minute.ex5`

Un binario sin fuente se conserva como evidencia, pero no se utilizará como fuente de verdad ni se inferirá su lógica sin evidencia adicional.

## 4. Divergencias críticas de instrumento

Se detectaron tres casos donde el nombre declara BTCUSD pero el código contiene evidencia de XAUUSD:

| Archivo | Nombre | Código |
|---|---|---|
| `ApexQuant BTCUSD.mq5` | BTCUSD | XAUUSD |
| `ApexQuant Institucional BTCUSD.mq5` | BTCUSD | XAUUSD |
| `Gemini BTCUSD.mq5` | BTCUSD | XAUUSD |

Esto puede significar renombrado incompleto, clonación de una versión anterior, pruebas sobre oro o un defecto real. **No se corrige automáticamente.**

## 5. Complejidad de configuración

Las generaciones avanzadas presentan una superficie de parámetros muy grande:

- `ApexQuant_V7.8-PRO.mq5`: 146 inputs / 3.143 líneas.
- `APEXQUANT_V78_DYNAMIC.mq5`: 156 inputs / 2.765 líneas.
- `APEXQUANT_V79_ASYMMETRIC.mq5`: 167 inputs / 2.181 líneas.
- `NeurAlgo V80.mq5`: 167 inputs / 2.301 líneas.
- `XAUUSD NeurAlgo M1.mq5`: 167 inputs / 2.084 líneas.
- `BTCUSD NeurAlgo M1.mq5`: 167 inputs / 2.082 líneas.
- `test.mq5`: 167 inputs / 1.902 líneas.

La cantidad de inputs no demuestra sobreajuste, pero sí justifica una auditoría específica de grados de libertad, dependencia entre parámetros, trials realizados y estabilidad out-of-sample.

## 6. Indicadores y componentes observados

En las fuentes MQL5 se detectaron, entre otros:

- `CTrade`
- medias móviles
- ATR
- RSI
- MACD
- ADX
- Stochastic
- Bollinger
- `OnTradeTransaction`
- `OrderSend`
- componentes identificables como ML/IA en algunas variantes

Esto confirma una base suficiente para reconstruir componentes, pero no permite concluir que dos EAs sean equivalentes solo porque compartan indicadores.

## 7. Broker

El análisis textual detectó referencias explícitas a Pepperstone en 14 fuentes. No detectó referencias explícitas a Exness en este conjunto.

Esto **no contradice** el contexto histórico del autor: un broker puede estar definido por configuración externa, cuenta, servidor o uso operacional sin aparecer en el código. Por ello Exness queda como asociación contextual pendiente de mapeo por versión.

## 8. Cronología

`CreationTime` de Windows/OneDrive no se considera confiable como fecha de desarrollo porque múltiples archivos aparecen creados/copiados en una misma ventana pese a tener `LastWriteTime` históricos distintos.

La cronología se reconstruirá mediante:

1. LastWriteTime.
2. contenido y comentarios de versión.
3. nombres de archivo.
4. dependencias.
5. hashes.
6. binario asociado.
7. logs/backtests.
8. contexto documentado del autor.

## 9. Terceros y material de referencia

Se mantiene separado:

- `Advisors/`
- `Examples/`
- `Free Robots/`
- `Market/`

No se mezclan con la genealogía de desarrollos propios.

## 10. Riesgos de ingeniería a investigar

### R1 — Complejidad monolítica
Las generaciones de 2.000–3.000 líneas con más de 100 inputs requieren separar señal, régimen, riesgo, ejecución, gestión de posiciones y telemetría.

### R2 — Divergencia de configuración
Los nombres de instrumento no siempre representan el símbolo utilizado por el código.

### R3 — Explosión de parámetros
Debe reconstruirse el número de configuraciones/procesos de optimización realizados antes de interpretar resultados históricos.

### R4 — Dependencia de broker
Spread, stops level, filling mode, contract size, digits, sesiones y ejecución pueden invalidar comparaciones entre brokers.

### R5 — Validación histórica insuficiente
Un backtest positivo no será tratado como evidencia de ventaja fuera de muestra.

### R6 — Evolución no trazable
La existencia de muchas copias hace necesario un registro de parent/child, fecha, hash, propósito y resultado.

## 11. Arquitectura objetivo

La siguiente generación no debe ser otra copia monolítica tipo V80/V81.

Se propone:

`Data -> Quality -> Regime -> Signal -> Confirmation -> Risk -> Execution -> Position Management -> Telemetry -> Evaluation`

Cada capa tendrá contratos claros y pruebas independientes.

## 12. Familias prioritarias

### Prioridad A — ApexQuant
Es la familia con mayor profundidad histórica y mayor cantidad de evolución. Se reconstruirá desde las primeras versiones hasta V7.x/V78/V79.

### Prioridad B — NeurAlgo
Se analizarán separadamente las variantes XAUUSD, BTCUSD, M1/M15, Gold Edition y V80.

### Prioridad C — Fenix MT5
No debe confundirse con el proyecto Fenix IQ Option/OTC. Aquí se investigará solo la genealogía MQL5.

### Prioridad D — estrategias auxiliares
Trendsniper, Gold ICT, breakout, SMC, Engulfing, Akali, Quantum Queen, Satoshi y ZRCE se usarán como fuentes de hipótesis/componentes, no como candidatos de producción hasta ser validados.

## 13. Política de rentabilidad

Objetivo: encontrar estrategias con evidencia de ventaja estadística y robustez suficiente para justificar investigación posterior.

No se garantiza rentabilidad. La promoción de una estrategia requerirá, como mínimo:

- definición pre-registrada;
- costes y ejecución realistas;
- separación train/test;
- out-of-sample;
- walk-forward;
- análisis de sensibilidad;
- stress testing;
- Monte Carlo;
- control de múltiples pruebas;
- forward demo;
- criterios explícitos de rechazo.

## 14. Estado

**MT5 historical corpus: PRESERVED / INVENTORIED / PARTIALLY CLASSIFIED**

Siguiente fase autorizada: genealogía y comparación estructural de ApexQuant y NeurAlgo, sin modificar los históricos.
