# PROJECT-STATUS.md — Trading-Ciencia

**Auditoría:** 2026-10-07  
**Rama auditada:** `main`  
**Visibilidad:** pública  
**Estado:** INVESTIGACIÓN / RECUPERACIÓN FORENSE EN PROGRESO

## Estado observado

- El repositorio contiene un framework científico de trading y documentación de investigación.
- Existe un PR #1 draft para recuperación forense del corpus histórico MT5/IQ Option.
- La rama del PR conserva históricos separados de terceros, análisis, inventarios SHA-256 y un registro provisional de genealogía.
- El inventario MT5 declara 186 archivos: 93 MQ5, 3 MQH y 90 EX5.
- El PR identifica 5 MQ5 sin EX5 y 2 EX5 sin MQ5.
- El análisis identifica divergencias de nombre BTCUSD frente a código XAUUSD que deben resolverse antes de comparar resultados.
- No se debe interpretar la recuperación forense como validación de rentabilidad.

## Correcciones de esta autoauditoría

1. Se restauró la codificación UTF-8 de `docs/00-foundation/03-risk-reality.md`, que había quedado corrupta en el PR.
2. Se eliminó el workflow `.github/workflows/docs.yml`, duplicado y con una interfaz de despliegue incompatible con la implementación de Pages ya contenida en `ci.yml`.
3. `ci.yml` dejó de declarar la rama inexistente `develop`; el repo observado solo tiene `main` como rama principal.
4. Se eliminó la referencia obsoleta a `HONEYTOKEN.md` de AGENTS.md.
5. Los históricos con posible material sensible permanecen fuera de los artefactos públicos según las reglas de `.gitignore`; no se deben incorporar credenciales ni archivos de cuentas.

## Validación científica

- Los inventarios y similitudes son evidencia de organización/forensia, no evidencia de edge.
- La similitud token/Jaccard se considera **screening**, no prueba de genealogía.
- Los resultados históricos no entran a rankings hasta pasar gates de instrumento, broker, timeframe, costes y validación fuera de muestra.
- El PR reporta una prueba local de 29 tests con un fallo temporal posterior y una prueba aislada posterior 5/5; esto no se considera una suite estable verificada por CI.

## Límites

- La ejecución actual de GitHub Actions del commit auditado no se considera observada hasta obtener evidencia de run.
- No se declara rentabilidad, producción ni seguridad histórica completa.
- La investigación de IQ Option/Fenix y MT5 se conserva separada de los componentes de producto.

## Próximo criterio de cierre

El PR #1 no se fusionará por el mero hecho de contener mucho material. Debe quedar con evidencia consistente de inventario, seguridad, encoding, navegación MkDocs, tests y clasificación de históricos. Solo entonces podrá pasar de draft a merge.
