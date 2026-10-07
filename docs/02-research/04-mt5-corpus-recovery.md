# Recuperación forense del corpus MT5

Este documento resume la recuperación histórica de desarrollos MetaTrader 5/MQL5 y remite al material técnico completo bajo research/projects/mt5/.

## Inventario inicial

La fuente histórica Experts contiene:

- 93 fuentes .mq5
- 3 fuentes .mqh
- 90 binarios .ex5
- 5 fuentes .mq5 sin binario correspondiente
- 2 binarios .ex5 sin fuente correspondiente

Los SHA-256, metadatos y correspondencias están en research/projects/mt5/00-audit/MT5-FULL-INVENTORY.csv y .json.

## Principios

1. Los históricos se preservan sin modificaciones.
2. Los ejemplos, robots gratuitos y material de Market se separan de los desarrollos propios.
3. Los nombres de versión no se consideran evidencia de superioridad.
4. Broker, instrumento y timeframe se clasifican con nivel de evidencia.
5. Rentabilidad es una hipótesis que requiere validación reproducible.

## Hallazgos importantes

Tres archivos llamados BTCUSD contienen evidencia de XAUUSD en el código:

- ApexQuant BTCUSD.mq5
- ApexQuant Institucional BTCUSD.mq5
- Gemini BTCUSD.mq5

No se corrigen automáticamente porque son evidencia histórica y primero debe reconstruirse la intención de cada snapshot.

Las generaciones avanzadas también muestran una expansión importante de parámetros, llegando a 167 inputs en varias fuentes. Esto exige controlar grados de libertad, múltiples pruebas y estabilidad fuera de muestra.

## Próxima etapa

La siguiente investigación prioriza la genealogía ApexQuant + NeurAlgo, seguida de Fenix MT5 y las estrategias auxiliares.

El material completo está organizado en research/projects/mt5/.

La investigación no autoriza por sí misma ejecución con dinero real.
