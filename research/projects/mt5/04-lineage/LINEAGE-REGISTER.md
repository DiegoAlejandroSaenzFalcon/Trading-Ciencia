# MT5 lineage register — provisional

**Date:** 2026-10-05  
**Status:** provisional / evidence-backed screening

## Family map

| Family | Scope | Current conclusion |
|---|---|---|
| ApexQuant | 15 sources | Principal historical branch; extensive evolution into institutional, dynamic and asymmetric variants. |
| NeurAlgo | 9 sources | Separate branch that converges structurally with late ApexQuant variants. |
| Fenix MT5 | 3 sources | MT5 family only; separate from IQ Option Fenix project. |
| Trendsniper | 2 sources | XAU/BTC variants; candidate comparative branch. |
| Quantum Queen | 2 sources | Two variants; needs behavioral comparison. |
| Akali | 2 sources | Two variants; likely related branch. |
| Engulfing | 3 sources | Three NY variants; strong similarity candidate. |
| Oro/Gold | 2+ sources | Gold-focused experiments; several structurally related candidates. |
| Gold ICT / breakout / SMC | 3 sources | Independent strategy experiments; hypothesis sources. |
| Satoshi | 1 source | BTC-focused experiment. |
| ZRCE | 1 source | EURUSD branch. |
| Diagnostic/experiment | several | Do not treat as production strategies. |

## Strong structural candidates

The token-similarity screen found:

- BTCUSD NeurAlgo M1 ↔ XAUUSD NeurAlgo M1: 0.993
- APEXQUANT V7.7-PRO ↔ ApexQuant MQL5: 0.989
- ApexQuant Institucional BTCUSD ↔ ApexQuant Institucional: 0.974
- APEXQUANT V79 ASYMMETRIC ↔ NeurAlgo V80: 0.963
- ApexQuant Diego Saenz ↔ ApexQuant Institucional XAUUSD: 0.952
- APEXQUANT V78 DYNAMIC ↔ APEXQUANT V79 ASYMMETRIC: 0.802
- Engulfingbull ny backtested ↔ EngulfingBull_NY_EA: 1.000 token vocabulary similarity

These are screening candidates, not proof that one file was copied from another. Confirmation requires line-level diff, chronology, comments, parameter semantics and behavior.

## Important discovery

The late NeurAlgo and ApexQuant branches are not isolated. Their source vocabularies and structures strongly overlap. This suggests that the future architecture should not arbitrarily choose one family as “the winner”; instead, we should reconstruct their common components and isolate the hypotheses that changed between generations.

## Immediate comparison set

The highest-value forensic comparison set is:

1. ApexQuant MQL5
2. APEXQUANT V7.7-PRO
3. ApexQuant V7.8-PRO
4. APEXQUANT V78 DYNAMIC
5. APEXQUANT V79 ASYMMETRIC
6. NeurAlgo V80
7. XAUUSD NeurAlgo M1
8. BTCUSD NeurAlgo M1
9. ApexQuant Institucional XAUUSD
10. ApexQuant Institucional BTCUSD

This set captures the transition from the ApexQuant institutional branch into dynamic/asymmetric logic and the parallel NeurAlgo branch.

## Instrument integrity gate

Before using any historical performance:

- resolve the three BTCUSD filename/XAUUSD-code divergences;
- confirm symbol constants versus _Symbol usage;
- inspect hard-coded contract assumptions;
- map broker-specific spread/point/tick-value assumptions;
- identify timeframe assumptions;
- identify external data dependencies.

No historical result should enter a comparative leaderboard until this gate passes.
