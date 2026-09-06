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

## Filosofía

| Principio | Cómo se implementa |
|-----------|-------------------|
| **Ciencia, no fe** | Pre-registro obligatorio (`falsification-ledger`) |
| **Honestidad por defecto** | Puertas fail-closed (`factor-qc`, `lookahead-free`) |
| **Evidencia antes que afirmación** | Hash-chain inmutable, adjudicación única |
| **Tu piel en el juego** | Demo → Real con tu capital, documentado |
| **Multi-disciplinario** | Psicología (`lesson-book`), Datos (`pit-adjuster`), Stats (`purgedcv`) |
| **Gratis y abierto** | MIT licenses, zero dependencies, local-first |
| **Periodismo neutral** | Reportes automáticos sin sesgo, gate `holdout-governance` |

---

## Inicio Rápido

### Prerrequisitos
- Python 3.11+
- Git
- Docker (opcional, para stack completo)
- Cuenta demo gratuita en [OANDA](https://www.oanda.com/demo-account) (Forex/Metales, XAUUSD nativo)

### Instalación

```bash
# Clonar repositorio
git clone https://github.com/DiegoSaenz/trading-science-framework.git
cd trading-science-framework

# Crear entorno virtual
python -m venv .venv
source .venv/bin/activate  # Linux/macOS
# .venv\Scripts\activate   # Windows

# Instalar dependencias
pip install -e ".[dev,notebooks,web,monitoring]"

# Configurar pre-commit hooks
pre-commit install

# Copiar configuración de ejemplo
cp .env.example .env
# Editar .env con tus API keys de OANDA demo
```

### Verificar instalación

```bash
# Ejecutar demos de la toolchain Holdout (validan que todo funciona)
python -m purgedcv.examples.demo
python -m factor_qc.examples.demo
python -m falsification_ledger.examples.demo
python -m lookahead_free.examples.demo
python -m pit_adjuster.examples.demo
python -m lesson_book.examples.demo

# Verificar CLI principal
tsf --help
```

---

## Estructura del Proyecto

```
trading-science-framework/
├── data/                    # Datos crudos + PIT rebuilt (gitignored)
│   ├── raw/                 # OANDA streaming dumps
│   ├── pit/                 # pit-adjuster outputs (hfq)
│   ├── audits/              # imm audit logs (append-only)
│   └── manifests/           # SHA-256 snapshots
├── research/                # Investigación científica
│   ├── hypotheses/          # fl preregister outputs
│   ├── pipelines/           # lf pipeline definitions
│   ├── backtests/           # CPCV paths + metrics
│   ├── evidence/            # fl submit reports
│   ├── adjudications/       # fl adjudicate records
│   └── artifacts/           # gov manifests (release candidates)
├── strategies/              # Implementaciones de estrategias
├── lessons/                 # lesson-book.jsonl (tuition memory)
├── monitoring/              # Prometheus rules, Grafana dashboards
├── deployment/              # Dockerfile, systemd, VPS setup
├── docs/                    # Documentación viva (MkDocs)
├── governance/              # policy.yml, gov configs
├── tsf/                     # Paquete principal Python
│   ├── cli.py               # CLI principal (typer)
│   ├── data/                # Módulo datos (OANDA, PIT, quality)
│   ├── research/            # Módulo investigación (hypothesis, pipeline)
│   ├── validation/          # Módulo validación (CPCV, gates)
│   ├── execution/           # Módulo ejecución (orders, risk)
│   ├── governance/          # Módulo gobernanza (manifests, gates)
│   └── psychology/          # Módulo psicología (lesson-book)
├── tests/                   # Tests unitarios + integración
├── examples/                # Ejemplos reproducibles
└── pyproject.toml           # Configuración proyecto
```

---

## Guía Secuencial de Aprendizaje (Desde Cero)

> **Importante:** Esta guía está diseñada para seguirse **en orden**. Cada fase construye sobre la anterior. No salte fases.

### Fase 0: Fundación — *Entender el Juego* (Semana 1)
- [ ] **0.1** Leer `docs/00-foundation/01-what-is-trading.md` — Qué es trading realmente
- [ ] **0.2** Leer `docs/00-foundation/02-scientific-method.md` — Método científico aplicado
- [ ] **0.3** Leer `docs/00-foundation/03-risk-reality.md` — Realidad del riesgo, drawdowns, ruin
- [ ] **0.4** Ejecutar `examples/00_foundation_demo.py` — Ver herramientas en acción
- [ ] **0.5** Configurar OANDA demo, obtener API keys, probar conexión

### Fase 1: Datos — *La Materia Prima* (Semana 2)
- [ ] **1.1** `docs/01-data/01-market-structure.md` — Estructura de mercado, sesiones, liquidez
- [ ] **1.2** `docs/01-data/02-pit-principle.md` — Point-in-Time: por qué los datos mienten
- [ ] **1.3** `docs/01-data/03-data-quality.md` — Limpieza, auditoría, snapshots
- [ ] **1.4** `examples/01_data_pipeline.py` — Streaming OANDA → PIT rebuild → quality gates

### Fase 2: Investigación — *Formular Preguntas Honestas* (Semana 3)
- [ ] **2.1** `docs/02-research/01-hypothesis-driven.md` — Hipótesis falsables, no "ideas que suenan bien"
- [ ] **2.2** `docs/02-research/02-pre-registration.md` — `falsification-ledger`: pre-registrar ANTES de ver datos
- [ ] **2.3** `docs/02-research/03-pipeline-design.md` — `lookahead-free`: diseñar pipelines verificables
- [ ] **2.4** `examples/02_research_workflow.py` — Flujo completo: hipótesis → pipeline → pre-registro

### Fase 3: Validación — *Separar Señal de Ruido* (Semana 4-5)
- [ ] **3.1** `docs/03-validation/01-backtest-traps.md` — Trampas del backtesting: overfitting, leakage, selection bias
- [ ] **3.2** `docs/03-validation/02-cpcv-dsr-pbo.md` — CPCV, DSR, PBO, MinTRL explicados con ejemplos
- [ ] **3.3** `docs/03-validation/03-factor-qc-gate.md` — `factor-qc`: puerta fail-closed, n_trials honesto
- [ ] **3.4** `examples/03_validation_rigorous.py` — Backtest honesto end-to-end

### Fase 4: Ejecución — *Del Papel a la Realidad* (Semana 6-7)
- [ ] **4.1** `docs/04-execution/01-order-management.md` — Órdenes, OCO, reconciliation, error handling
- [ ] **4.2** `docs/04-execution/02-risk-management.md` — Sizing, breakers, cooldowns, session filters
- [ ] **4.3** `docs/04-execution/03-paper-trading.md` — Demo extensiva: 30-60 días mínimo
- [ ] **4.4** `examples/04_execution_demo.py` — Paper trading con gates de calidad

### Fase 5: Psicología — *Tu Mayor Enemigo* (Semana 8)
- [ ] **5.1** `docs/05-psychology/01-cognitive-biases.md` — Sesgos cognitivos en trading
- [ ] **5.2** `docs/05-psychology/02-tuition-memory.md` — `lesson-book`: registrar errores, match pre-acción
- [ ] **5.3** `docs/05-psychology/03-discipline-systems.md` — Checklists, premortems, rutinas
- [ ] **5.4** `examples/05_psychology_integration.py` — Integración completa en loop diario

### Fase 6: Gobernanza — *Evidencia Antes que Acción* (Semana 9)
- [ ] **6.1** `docs/06-governance/01-holdout-governance.md` — Manifests, gates, release process
- [ ] **6.2** `docs/06-governance/02-ci-cd.md` — GitHub Actions, pre-commit, deployment
- [ ] **6.3** `examples/06_governance_workflow.py` — Flujo completo: investigación → artefacto → release

### Fase 7: Producción — *Vivir el Proceso* (Semana 10+)
- [ ] **7.1** `docs/07-production/01-vps-setup.md` — VPS, Docker, systemd, monitoring
- [ ] **7.2** `docs/07-production/02-observability.md` — Prometheus, Grafana, alertas
- [ ] **7.3** `docs/07-production/03-runbook.md` — Deploy, rollback, disaster recovery
- [ ] **7.4** `examples/07_production_deploy.py` — Deploy automatizado

### Fase 8: Contribución — *Devolver al Común* (Continuo)
- [ ] **8.1** `docs/08-contribution/01-trader-registry.md` — Documentar traders honestos verificados
- [ ] **8.2** `docs/08-contribution/02-publishing.md` — Publicar hallazgos, post-mortems, metodología
- [ ] **8.3** `docs/08-contribution/03-community.md` — Colaborar, revisar, mejorar el framework

---

## Toolchain Científica Integrada (Holdout Labs)

| Herramienta | Propósito | Comando Principal |
|-------------|-----------|-------------------|
| **purgedcv** | CPCV, DSR, PBO, PSR, MinTRL | `purgedcv` / `from purgedcv import *` |
| **factor-qc** | Puerta fail-closed: DSR/PBO/Haircut/MinTRL | `qc check --returns ... --n-trials ...` |
| **falsification-ledger** | Pre-registro, hash-chain, adjudicación, hit-rate | `fl preregister / submit / adjudicate / report` |
| **lookahead-free** | Verificación temporal de pipelines (DAG) | `lf check --pipeline pipeline.json` |
| **pit-adjuster** | Reconstrucción PIT hfq, drift detection | `padj rebuild / invert-check / drift-check` |
| **lesson-book** | Tuition memory: errores → recordatorios pre-acción | `lb add / match / review` |
| **holdout-governance** | Manifest único, release gate, CI integration | `gov check / report / validate / health` |

Todas son **MIT license**, **zero/minimal dependencies**, **local-first**, **Windows/Linux/macOS**.

---

## Estrategias de Referencia (No Impuestas)

El framework **no impone ninguna estrategia**. Incluye implementaciones de referencia para estudio:

- **KalmanATR Scalper** — Port del EA MQL5 original (XAUUSD M5), guardado como referencia histórica
- **Mean Reversion** — Ejemplo educativo con validación completa
- **Trend Following** — Ejemplo educativo multi-activo
- **Tu estrategia aquí** — El framework te guía para construir y validar la tuya

> **Nota:** La estrategia KalmanATR se conserva en `strategies/references/kalman_atr/` por valor histórico (dio indicios positivos en backtest), **no porque sea "la buena"**. El proceso científico determinará su validez real.

---

## Documentación

- **Web (GitHub Pages):** https://diegosaenz.github.io/trading-science-framework/
- **Local:** `mkdocs serve` → http://localhost:8000
- **PDF:** `mkdocs build` → `site/` → imprimir a PDF

---

## Licencia

**MIT License** — Libre uso, modificación, distribución, uso comercial.  
**Requisito único:** Atribución a **Diego Saenz** como autor original.

```text
Copyright (c) 2026 Diego Saenz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Autor

**Diego Saenz** — Investigador independiente, trader retail, desarrollador.  
GitHub: [@DiegoSaenz](https://github.com/DiegoSaenz)  
Contacto: Issues del repositorio (público, transparente)

---

## Agradecimientos

Este framework se apoya en los hombros de gigantes:

- **Marcos López de Prado** — *Advances in Financial Machine Learning* (fundamentos matemáticos)
- **David Bailey & Marcos López de Prado** — DSR, PBO, MinTRL (validación honesta)
- **Campbell Harvey, Yan Liu, Heqing Zhu** — Multiple testing corrections
- **Holdout Labs** — Toolchain completa de integridad científica (pit-adjuster, falsification-ledger, factor-qc, lookahead-free, lesson-book, holdout-governance)
- **OANDA** — API v20 gratuita para demo/real, Forex/Metales nativos
- **Comunidad Python Quant** — numpy, pandas, vectorbt, backtrader, ta-lib

---

## Contribuir

1. Fork del repo
2. Crear rama: `git checkout -b feature/mi-mejora`
3. Commits convencionales: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`
4. Tests pasan: `pytest`
5. Lint limpio: `ruff check . && mypy tsf`
6. PR con descripción clara del qué y por qué

---

## Seguridad

- **NUNCA** commitear API keys, secrets, tokens
- Usar `.env` (gitignored) + `.env.example` (template)
- Reportar vulnerabilidades: Security Advisory en GitHub (privado)
- El framework **no ejecuta órdenes automáticamente sin gates** — humano en el loop

---

## Disclaimer

> **Este software es para fines educativos e investigativos.**  
> **No constituye asesoramiento financiero.**  
> **El trading conlleva riesgo de pérdida total del capital.**  
> **Nunca arriesgue dinero que no pueda permitirse perder.**  
> **Valide SIEMPRE en demo extensiva antes de capital real.**  
> **Los resultados pasados no garantizan resultados futuros.**

---

*Construido con honestidad intelectual, rigor científico y la convicción de que el trading puede abordarse como ciencia —no como apuesta— cuando se aplican las herramientas correctas.*