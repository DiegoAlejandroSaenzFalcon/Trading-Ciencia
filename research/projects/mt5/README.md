# MT5 — Forensic Recovery & Research

**Estado:** investigación histórica / reconstrucción.  
**Fecha de incorporación:** 2026-10-05.  
**Origen principal:** `C:\Users\Diego Saenz\OneDrive\Diego\Experts`.  
**Plataforma:** MetaTrader 5 / MQL5.

## Propósito

Este proyecto conserva y analiza los desarrollos históricos de EAs y utilidades MQL5 del autor para reconstruir su genealogía, recuperar decisiones técnicas útiles y diseñar generaciones nuevas con ingeniería profesional y validación científica.

No se considera que una versión histórica sea rentable, superior o apta para producción por su nombre, número de versión, backtest antiguo o apariencia del código. Toda afirmación de desempeño debe estar respaldada por evidencia reproducible.

## Fuentes y preservación

La fuente original de `Experts` **no se modifica ni se utiliza como zona experimental**.

La copia de investigación se organiza en:

- `00-audit/` — inventarios, hashes, hallazgos y auditorías.
- `01-source/legacy/` — fuentes MQL5 propias o aún no atribuidas con certeza.
- `01-source/third-party/` — ejemplos, robots gratuitos y material de Market/Advisors separado de los desarrollos propios.
- `02-binaries-manifest/` — evidencia de binarios compilados sin convertirlos en fuente de verdad.
- `03-analysis/` — análisis estático, similitud, métricas y scripts reproducibles.
- `04-lineage/` — genealogía de familias/versiones.
- `05-evidence/` — backtests, logs y resultados verificables.
- `06-hypotheses/` — hipótesis falsables y preregistros.
- `07-next-generation/` — arquitectura y futuras implementaciones, separadas de los históricos.

## Resultado del inventario inicial

El inventario forense del 2026-10-05 encontró **186 archivos** bajo `Experts` con extensiones `.mq5`, `.mqh` y `.ex5`:

- 93 `.mq5`
- 3 `.mqh`
- 90 `.ex5`
- 5 fuentes `.mq5` sin binario `.ex5`
- 2 binarios `.ex5` sin fuente `.mq5`

El inventario completo y sus SHA-256 están en:

- `00-audit/MT5-FULL-INVENTORY.csv`
- `00-audit/MT5-FULL-INVENTORY.json`
- `00-audit/MT5-INVENTORY-SUMMARY.txt`

## Separación de material

Los subdirectorios históricos de `Experts` como `Examples`, `Free Robots`, `Advisors` y `Market` se tratan como **referencia de terceros**, no como desarrollos propios, hasta demostrar procedencia distinta.

Los proyectos Fenix de IQ Option/OTC están fuera de este árbol y se investigan en:

`research/projects/iq-option/fenix/`

No se mezclan con MT5 porque representan otra plataforma, API y microestructura.

## Broker

La evidencia textual de broker se registra a nivel de archivo. En el primer inventario aparecen referencias explícitas a Pepperstone en 14 fuentes. La ausencia de una cadena de broker **no demuestra** que el EA no se haya usado con ese broker.

Las asociaciones Pepperstone/Exness proporcionadas por el autor se conservarán como contexto de investigación y se mapearán a cada versión únicamente cuando exista evidencia suficiente (código, comentarios, configuración, logs, historial o contexto fechado).

## Hallazgos iniciales relevantes

1. Existen tres divergencias claras entre nombre e instrumento detectado en código:
   - `ApexQuant BTCUSD.mq5` contiene evidencia de XAUUSD.
   - `ApexQuant Institucional BTCUSD.mq5` contiene evidencia de XAUUSD.
   - `Gemini BTCUSD.mq5` contiene evidencia de XAUUSD.

   No se corregirán todavía: son evidencia histórica y primero deben reconstruirse sus intenciones y dependencias.

2. La superficie de configuración creció fuertemente en las generaciones avanzadas. Varias fuentes superan 120 inputs y cinco alcanzan 167. Esto es un indicador de complejidad experimental y posible riesgo de sobreajuste; no es por sí solo un defecto.

3. La mayoría de las fuentes propias detectadas usan `CTrade`, y una parte importante utiliza ATR, medias, RSI, MACD y ADX. Esto permite buscar componentes reutilizables, pero no asumir que las implementaciones son equivalentes.

4. No se detectaron duplicados exactos por SHA-256 entre las fuentes MQL5 inventariadas.

5. Los tiempos de creación de Windows/OneDrive no se usarán como cronología primaria. Se priorizará `LastWriteTime`, contenido, nomenclatura, dependencias, hashes y evidencia documental. La fecha de copia a OneDrive puede distorsionar `CreationTime`.

## Metodología de reconstrucción

Para cada familia:

1. Preservar snapshot y SHA-256.
2. Identificar plataforma, broker, instrumento y timeframe con nivel de evidencia.
3. Extraer arquitectura, entradas, indicadores, gestión de riesgo, ejecución y telemetría.
4. Detectar divergencias nombre/código.
5. Construir genealogía verificable.
6. Identificar defectos, regresiones y decisiones que sí merezcan rescate.
7. Separar hipótesis de hechos observados.
8. Diseñar una arquitectura modular de siguiente generación.
9. Reimplementar sin contaminar los históricos.
10. Compilar y probar.
11. Validar con costes realistas, out-of-sample, walk-forward, stress/Monte Carlo y forward demo antes de considerar cualquier uso real.

## Estado científico

Los históricos son **LEGACY / UNVALIDATED** hasta demostrar lo contrario.

La palabra “rentable” se tratará como una hipótesis que debe ser demostrada bajo un protocolo de validación, no como una propiedad asumida del proyecto.

## Regla de cambios

No se edita `01-source/legacy/` para desarrollar nuevas versiones. Los cambios se realizan sobre snapshots o implementaciones nuevas bajo `07-next-generation/`.

La rama actual de trabajo es:

`audit/mt5-forensic-recovery-2026-10-05`

No se fusiona automáticamente a `main`.
