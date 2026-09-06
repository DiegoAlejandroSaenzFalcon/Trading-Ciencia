# Guía de Inicio Rápido

> **Tiempo estimado: 30-60 minutos para setup completo**

---

## Prerrequisitos

| Requisito | Versión Mínima | Verificar |
|-----------|----------------|-----------|
| Python | 3.11+ | `python --version` |
| Git | 2.30+ | `git --version` |
| Docker (opcional) | 24+ | `docker --version` |
| Cuenta OANDA Demo | Gratis | [Registrarse](https://www.oanda.com/demo-account) |

---

## 1. Clonar e Instalar

```bash
# Clonar repositorio
git clone https://github.com/DiegoAlejandroSaenzFalcon/trading-science-framework.git
cd trading-science-framework

# Crear entorno virtual aislado
python -m venv .venv

# Activar (Linux/macOS)
source .venv/bin/activate

# Activar (Windows PowerShell)
.venv\Scripts\Activate.ps1

# Activar (Windows CMD)
.venv\Scripts\activate.bat

# Actualizar pip
pip install --upgrade pip

# Instalar framework en modo desarrollo + extras
pip install -e ".[dev,notebooks,web,monitoring]"

# Configurar pre-commit hooks (lint, types, tests, gov check)
pre-commit install
```

---

## 2. Configurar Credenciales

```bash
# Copiar template
cp .env.example .env

# Editar con tus valores REALES
# MÍNIMO REQUERIDO:
# OANDA_ACCOUNT_ID=tu-account-id-demo
# OANDA_API_KEY=tu-api-key-demo
```

**Obtener credenciales OANDA Demo:**
1. Regístrate en https://www.oanda.com/demo-account
2. Inicia sesión → My Account → API Access → Manage API Access
3. Genera "Personal Access Token" (scope: Account + Trade + Data)
4. Copia Account ID y API Key a `.env`

---

## 3. Inicializar Proyecto

```bash
# Crea estructura completa, configs, templates, git hooks
tsf init

# Verifica configuración
tsf --check-config
```

Deberías ver:
```
✅ Configuración completamente válida
```

---

## 4. Verificar Toolchain Holdout

```bash
# Ejecutar TODAS las demos de la toolchain científica
tsf demo --phase 0
```

Esto verifica que `purgedcv`, `factor-qc`, `falsification-ledger`, `lookahead-free`, `pit-adjuster`, `lesson-book`, `holdout-governance` están instalados y funcionando.

---

## 5. Empezar la Guía Secuencial

```bash
# Servir documentación local
mkdocs serve
# Abre http://localhost:8000

# O leer directamente:
# docs/00-foundation/01-what-is-trading.md
```

---

## Estructura Resultante

```
trading-science-framework/
├── .env                    # TUS credenciales (NUNCA commit)
├── .gitignore              # Protege datos, secrets, artifacts
├── pyproject.toml          # Configuración proyecto
├── mkdocs.yml              # Documentación
├── data/                   # Datos (gitignored)
│   ├── raw/                # OANDA streaming dumps
│   ├── pit/                # PIT rebuilt (hfq)
│   ├── audits/             # Quality audit logs
│   └── manifests/          # SHA-256 snapshots
├── research/               # Investigación (gitignored)
│   ├── hypotheses/         # fl preregister outputs
│   ├── pipelines/          # lf pipeline definitions
│   ├── backtests/          # CPCV paths + metrics
│   ├── evidence/           # fl submit reports
│   ├── adjudications/      # fl adjudicate records
│   └── artifacts/          # gov manifests
├── strategies/             # Implementaciones
│   ├── references/         # KalmanATR (histórico)
│   └── templates/          # Base strategy template
├── lessons/                # lesson-book.jsonl (gitignored)
├── governance/             # policy.yml, ledger, watchlist
├── monitoring/             # Prometheus, Grafana
├── deployment/             # Docker, systemd, scripts
├── docs/                   # Documentación MkDocs
├── tsf/                    # Paquete Python principal
└── tests/                  # Tests unitarios + integración
```

---

## Comandos Esenciales

```bash
# Verificar config
tsf --check-config

# Demos por fase
tsf demo --phase 1  # Datos
tsf demo --phase 2  # Investigación
tsf demo --phase 3  # Validación
# ...

# CLI principal por fases
tsf data --help      # Streaming, fetch, PIT, quality
tsf research --help  # Hipótesis, pipeline, pre-registro
tsf validate --help  # CPCV, métricas, gate factor-qc
tsf execute --help   # Paper, live, risk, reconcile
tsf govern --help    # Manifests, gates, CI
tsf learn --help     # Tuition memory, premortems

# Desarrollo
pytest                    # Tests
ruff check .              # Lint
mypy tsf                  # Types
mkdocs serve              # Docs local
```

---

## Siguiente Paso

👉 **[Fase 0: Fundación — Qué es Trading Realmente](00-foundation/01-what-is-trading.md)**

Entender la naturaleza real del trading antes de escribir una sola línea de código.