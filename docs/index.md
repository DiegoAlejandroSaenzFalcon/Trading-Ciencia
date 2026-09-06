# Trading Science Framework

> **Marco de Investigación Científica Aplicada al Trading — Libre, Honesto, Verificable**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![Status: Alpha](https://img.shields.io/badge/status-alpha-orange.svg)](https://github.com/DiegoSaenz/trading-science-framework)
[![GitHub Pages](https://img.shields.io/badge/docs-github_pages-brightgreen.svg)](https://diegosaenz.github.io/trading-science-framework/)

---

## ¿Qué es esto?

**No es un bot de trading.**  
**No es un curso.**  
**No vende señales, no promete riquezas, no oculta riesgos.**

Es un **marco de investigación** para que **cualquier persona**, desde cero, pueda:

1. **Aprender trading como ciencia** — metodología, validación, evidencia
2. **Probar estrategias con rigor** — backtesting honesto, sin look-ahead, sin data snooping
3. **Documentar su proceso** — pre-registro, adjudicación, hit-rate vs baseline
4. **Gestionar su psicología** — tuition memory, checklists, premortems automatizados
5. **Operar en demo → real** — con gates de calidad que protegen su capital
6. **Contribuir al conocimiento colectivo** — abierto, reproducible, auditable

---

## Inicio Rápido

```bash
# 1. Clonar
git clone https://github.com/DiegoSaenz/trading-science-framework.git
cd trading-science-framework

# 2. Entorno virtual
python -m venv .venv
source .venv/bin/activate  # Linux/macOS
# .venv\Scripts\activate   # Windows

# 3. Instalar
pip install -e ".[dev,notebooks,web,monitoring]"
pre-commit install

# 4. Configurar
cp .env.example .env
# Editar .env con tus API keys OANDA demo

# 5. Inicializar proyecto
tsf init

# 6. Verificar toolchain
tsf demo --phase 0
```

---

## La Guía Secuencial (Desde Cero)

> **Sigue en orden. Cada fase construye sobre la anterior.**

| Fase | Tema | Duración | Objetivo |
|------|------|----------|----------|
| **0** | Fundación | 1 semana | Entender qué es trading, método científico, realidad del riesgo |
| **1** | Datos | 1 semana | Obtención, limpieza, PIT rebuild, quality gates |
| **2** | Investigación | 1 semana | Hipótesis falsables, pre-registro, pipelines verificables |
| **3** | Validación | 2 semanas | CPCV, DSR, PBO, MinTRL, gate factor-qc fail-closed |
| **4** | Ejecución | 2 semanas | Paper trading, risk management, order management |
| **5** | Psicología | 1 semana | Tuition memory, premortems, disciplina sistemática |
| **6** | Gobernanza | 1 semana | Manifests, release gates, CI/CD |
| **7** | Producción | 1+ semanas | VPS, observabilidad, runbook |
| **8** | Contribución | Continuo | Registro traders, publicación, comunidad |

[Empezar Fase 0 →](00-foundation/01-what-is-trading.md)

---

## Toolchain Científica Integrada (Holdout Labs)

Todas **MIT license**, **zero/minimal deps**, **local-first**, **Windows/Linux/macOS**.

| Herramienta | Propósito | Comando |
|-------------|-----------|---------|
| **purgedcv** | CPCV, DSR, PBO, PSR, MinTRL | `purgedcv` |
| **factor-qc** | Gate fail-closed: DSR/PBO/Haircut/MinTRL | `qc check` |
| **falsification-ledger** | Pre-registro, hash-chain, adjudicación, hit-rate | `fl` |
| **lookahead-free** | Verificación temporal pipelines (DAG) | `lf check` |
| **pit-adjuster** | Reconstrucción PIT hfq, drift detection | `padj` |
| **lesson-book** | Tuition memory: errores → recordatorios pre-acción | `lb` |
| **holdout-governance** | Manifest único, release gate, CI integration | `gov` |

---

## Filosofía

| Principio | Implementación |
|-----------|----------------|
| **Ciencia, no fe** | Pre-registro obligatorio (`falsification-ledger`) |
| **Honestidad por defecto** | Puertas fail-closed (`factor-qc`, `lookahead-free`) |
| **Evidencia antes que afirmación** | Hash-chain inmutable, adjudicación única |
| **Tu piel en el juego** | Demo → Real con tu capital, documentado |
| **Multi-disciplinario** | Psicología (`lesson-book`), Datos (`pit-adjuster`), Stats (`purgedcv`) |
| **Gratis y abierto** | MIT licenses, zero dependencies, local-first |
| **Periodismo neutral** | Reportes automáticos sin sesgo, gate `holdout-governance` |

---

## Estrategias de Referencia (No Impuestas)

El framework **no impone ninguna estrategia**. Incluye implementaciones de referencia para estudio:

- **KalmanATR Scalper** — Port del EA MQL5 original (XAUUSD M5), guardado como referencia histórica
- **Mean Reversion** — Ejemplo educativo con validación completa
- **Trend Following** — Ejemplo educativo multi-activo
- **Tu estrategia aquí** — El framework te guía para construir y validar la tuya

> **Nota:** La estrategia KalmanATR se conserva por valor histórico (dio indicios positivos en backtest), **no porque sea "la buena"**. El proceso científico determinará su validez real.

---

## Documentación

- **Web (GitHub Pages):** https://diegosaenz.github.io/trading-science-framework/
- **Local:** `mkdocs serve` → http://localhost:8000

---

## Autor

**Diego Saenz** — Investigador independiente, trader retail, desarrollador.  
GitHub: [@DiegoSaenz](https://github.com/DiegoSaenz)

---

## Licencia

**MIT License** — Libre uso, modificación, distribución, uso comercial.  
**Requisito único:** Atribución a **Diego Saenz** como autor original.

---

## Disclaimer

> **Este software es para fines educativos e investigativos.**  
> **No constituye asesoramiento financiero.**  
> **El trading conlleva riesgo de pérdida total del capital.**  
> **Nunca arriesgue dinero que no pueda permitirse perder.**  
> **Valide SIEMPRE en demo extensiva antes de capital real.**  
> **Los resultados pasados no garantizan resultados futuros.**