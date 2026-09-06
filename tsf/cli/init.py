"""
CLI Inicialización del proyecto.

Crea estructura completa, configs, templates, y verifica instalación.
"""

import shutil
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn

from ..config import settings

app = typer.Typer(name="init", help="Inicializar estructura completa del proyecto", no_args_is_help=True)
console = Console()


def initialize_project(force: bool = False) -> None:
    """Inicializar proyecto completo."""
    console.print(Panel.fit(
        "[bold]Inicializando Trading Science Framework[/bold]\n"
        "Creando estructura, configs, templates y verificando instalación",
        border_style="cyan"
    ))

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        # 1. Directorios base
        task = progress.add_task("Creando directorios...", total=None)
        _create_directories(force)
        progress.update(task, completed=True)

        # 2. Archivos de configuración
        task = progress.add_task("Creando configs...", total=None)
        _create_configs(force)
        progress.update(task, completed=True)

        # 3. Templates de gobernanza
        task = progress.add_task("Creando templates gobernanza...", total=None)
        _create_governance_templates(force)
        progress.update(task, completed=True)

        # 4. Templates de investigación
        task = progress.add_task("Creando templates investigación...", total=None)
        _create_research_templates(force)
        progress.update(task, completed=True)

        # 5. Templates de estrategias
        task = progress.add_task("Creando templates estrategias...", total=None)
        _create_strategy_templates(force)
        progress.update(task, completed=True)

        # 6. Git hooks
        task = progress.add_task("Configurando git hooks...", total=None)
        _setup_git_hooks(force)
        progress.update(task, completed=True)

        # 7. Verificación final
        task = progress.add_task("Verificando instalación...", total=None)
        _verify_installation()
        progress.update(task, completed=True)

    console.print(Panel.fit(
        "[bold green]✅ Inicialización completada[/bold green]\n\n"
        "Próximos pasos:\n"
        "1. Edita [cyan].env[/cyan] con tus API keys de OANDA demo\n"
        "2. Ejecuta [cyan]tsf demo --phase 0[/cyan] para verificar toolchain\n"
        "3. Empieza la Fase 0: [cyan]docs/00-foundation/01-what-is-trading.md[/cyan]",
        border_style="green"
    ))


def _create_directories(force: bool) -> None:
    """Crear estructura de directorios completa."""
    dirs = [
        # Data
        "data/raw", "data/pit", "data/audits", "data/manifests",
        # Research
        "research/hypotheses", "research/pipelines", "research/backtests",
        "research/evidence", "research/adjudications", "research/artifacts",
        # Strategies
        "strategies/references/kalman_atr", "strategies/templates",
        # Lessons
        "lessons",
        # Monitoring
        "monitoring/prometheus", "monitoring/grafana/dashboards",
        # Deployment
        "deployment/docker", "deployment/systemd", "deployment/scripts",
        # Docs
        "docs/00-foundation", "docs/01-data", "docs/02-research",
        "docs/03-validation", "docs/04-execution", "docs/05-psychology",
        "docs/06-governance", "docs/07-production", "docs/08-contribution",
        # Governance
        "governance",
        # Tests
        "tests/unit", "tests/integration", "tests/fixtures",
        # Examples
        "examples",
        # Configs
        "config",
    ]

    for dir_path in dirs:
        full_path = settings.project_root / dir_path
        if full_path.exists() and not force:
            continue
        full_path.mkdir(parents=True, exist_ok=True)
        # .gitkeep para directorios vacíos
        gitkeep = full_path / ".gitkeep"
        if not gitkeep.exists():
            gitkeep.write_text("")


def _create_configs(force: bool) -> None:
    """Crear archivos de configuración base."""
    configs = {
        "config/paper.yaml": """# Paper Trading Configuration
mode: paper
strategy: strategies/references/kalman_atr/strategy.py
symbol: XAUUSD
timeframe: M5
duration_days: 30
dry_run: true
risk:
  sizing_mode: 2
  risk_pct_equity: 0.5
  max_lots: 1.0
  sl_mult_atr: 1.5
  tp_r_multiple: 2.0
  cooldown_minutes: 10
  max_trades_per_day: 5
  daily_loss_limit_pct: 2.0
""",
        "config/live.yaml": """# Live Trading Configuration (SOLO TRAS VALIDACIÓN EXTENSA)
mode: live
strategy: strategies/references/kalman_atr/strategy.py
symbol: XAUUSD
timeframe: M5
risk:
  sizing_mode: 2
  risk_pct_equity: 0.5
  max_lots: 1.0
  sl_mult_atr: 1.5
  tp_r_multiple: 2.0
  cooldown_minutes: 10
  max_trades_per_day: 5
  daily_loss_limit_pct: 2.0
# REQUIERE: human_approval=true, factor-qc PASS, falsification-ledger support
""",
        "config/risk.yaml": """# Risk Management Parameters
sizing:
  mode: 2  # 0=fixed, 1=usd_risk, 2=pct_equity
  fixed_lots: 0.05
  risk_usd: 20.0
  risk_pct_equity: 0.5
  max_lots: 1.0

stops:
  sl_mult_atr: 1.5
  tp_r_multiple: 2.0

limits:
  cooldown_minutes: 10
  max_trades_per_day: 5
  daily_loss_limit_pct: 2.0

session:
  enabled: true
  start_hour: 13
  end_hour: 20
""",
        "config/backtest.yaml": """# Backtesting / Validation Configuration
cpcv:
  n_splits: 12
  n_test_groups: 6
  periods_per_year: 252

metrics:
  min_trials: 5
  benchmark_sharpe: 0.0
  alpha: 0.05

gate:
  dsr_threshold: 0.5
  pbo_threshold: 0.05
  haircut_method: "holm"
  mintrl_multiplier: 1.0
""",
        "governance/policy.yml": """# Holdout Governance Policy
version: "0.2"
artifact_type: "research_conclusion"

gates:
  data_integrity:
    required: true
    tools: ["imm", "padj"]
    max_age_hours: 24

  timing:
    required: true
    tools: ["lf"]
    max_age_hours: 24

  statistical_quality:
    required: true
    tools: ["qc"]
    max_age_hours: 168  # 1 week

  falsification:
    required: true
    tools: ["fl"]
    max_age_hours: 168

conditional_attachments:
  - when:
      declarations.contains_returns: true
    require:
      - limitations
      - sources

review:
  required: true
  min_reviewers: 1
  roles: ["research-owner"]

release:
  auto_on_pass: false
  require_human_approval: true
""",
        "governance/watchlist.json": """[
  {"code": "XAUUSD", "name": "Gold vs USD", "active": true},
  {"code": "BTCUSD", "name": "Bitcoin vs USD", "active": false},
  {"code": "EURUSD", "name": "Euro vs USD", "active": false}
]
""",
    }

    for path, content in configs.items():
        full_path = settings.project_root / path
        if full_path.exists() and not force:
            continue
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content)


def _create_governance_templates(force: bool) -> None:
    """Crear templates de gobernanza."""
    templates = {
        "governance/artifact.template.json": """{
  "schema_version": "holdout.artifact.v0.2",
  "artifact_id": "{{ARTIFACT_ID}}",
  "artifact_type": "research_conclusion",
  "title": "{{TITLE}}",
  "created_at": "{{CREATED_AT}}",
  "updated_at": "{{UPDATED_AT}}",
  "status": "draft",
  "decision": "pending",
  "hypothesis_ref": "{{HYPOTHESIS_ID}}",
  "pipeline_ref": "{{PIPELINE_ID}}",
  "backtest_ref": "{{BACKTEST_ID}}",
  "evidence_refs": [],
  "attachments": {},
  "declarations": {
    "contains_returns": false,
    "contains_recommendations": false
  },
  "limitations": "",
  "sources": [],
  "gate_evidence": {},
  "review": {
    "reviewer": "",
    "reviewed_at": "",
    "approved": false,
    "notes": ""
  }
}
""",
    }

    for path, content in templates.items():
        full_path = settings.project_root / path
        if full_path.exists() and not force:
            continue
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content)


def _create_research_templates(force: bool) -> None:
    """Crear templates de investigación."""
    templates = {
        "research/templates/hypothesis.template.json": """{
  "schema_version": "tsf.hypothesis.v1",
  "hypothesis_id": "{{HYPOTHESIS_ID}}",
  "created_at": "{{CREATED_AT}}",
  "description": "{{DESCRIPTION}}",
  "expected_direction": "{{DIRECTION}}",
  "source_type": "pipeline",
  "falsification_contract": {
    "kill_criteria": [
      {"metric": "dsr", "threshold": 0.5, "operator": "<"},
      {"metric": "pbo", "threshold": 0.05, "operator": ">"},
      {"metric": "mintrl", "threshold": "{{SAMPLE_SIZE}}", "operator": ">"}
    ],
    "description": "Evidencia que refutaría la hipótesis"
  },
  "status": "draft",
  "metadata": {
    "author": "Diego Alejandro Saenz Falcon",
    "framework_version": "0.1.0"
  }
}
""",
        "research/templates/pipeline.template.json": """{
  "name": "{{PIPELINE_NAME}}",
  "operations": [
    {
      "op_id": "read_bars",
      "kind": "read",
      "outputs": ["raw_bars"],
      "release": "{{RELEASE_TIME}}"
    },
    {
      "op_id": "pit_adjust",
      "kind": "pit_read",
      "inputs": ["raw_bars"],
      "outputs": ["hfq_bars"],
      "read_cutoff": "{{PIT_CUTOFF}}"
    },
    {
      "op_id": "calculate_indicators",
      "kind": "transform",
      "inputs": ["hfq_bars"],
      "outputs": ["indicators"]
    },
    {
      "op_id": "generate_signal",
      "kind": "decision",
      "inputs": ["indicators"],
      "outputs": ["signal"],
      "decision_time": "{{DECISION_TIME}}"
    }
  ]
}
""",
    }

    for path, content in templates.items():
        full_path = settings.project_root / path
        if full_path.exists() and not force:
            continue
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content)


def _create_strategy_templates(force: bool) -> None:
    """Crear templates de estrategias."""
    templates = {
        "strategies/templates/base_strategy.py": '''"""
Base Strategy Template

Toda estrategia DEBE implementar esta interfaz.
No hay lógica de trading aquí — solo estructura.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Optional
import numpy as np
import pandas as pd


@dataclass
class Signal:
    """Señal de trading con metadata completa para trazabilidad."""
    timestamp: datetime
    symbol: str
    direction: Literal["long", "short"]
    entry_price: float
    stop_loss: float
    take_profit: float
    size: float
    # Metadata para investigación
    strategy_name: str
    strategy_version: str
    hypothesis_id: str
    indicators: dict  # Valores de indicadores al momento de la señal
    regime: str  # Contexto de mercado (trending/ranging/volatile)
    confidence: float  # 0-1, basado en validación histórica


class BaseStrategy(ABC):
    """Clase base para todas las estrategias."""

    name: str = "base"
    version: str = "0.1.0"
    hypothesis_id: str = ""

    def __init__(self, config: dict):
        self.config = config
        self._validate_config()

    @abstractmethod
    def _validate_config(self) -> None:
        """Validar configuración requerida."""

    @abstractmethod
    def calculate_indicators(self, data: pd.DataFrame) -> pd.DataFrame:
        """Calcular indicadores — DEBE ser determinista y vectorizado."""

    @abstractmethod
    def generate_signals(self, data: pd.DataFrame) -> list[Signal]:
        """Generar señales — DEBE usar solo datos disponibles en timestamp."""

    @abstractmethod
    def get_required_history(self) -> int:
        """Número mínimo de barras históricas requeridas."""

    def get_metadata(self) -> dict:
        """Metadata para trazabilidad en investigación."""
        return {
            "strategy_name": self.name,
            "strategy_version": self.version,
            "hypothesis_id": self.hypothesis_id,
            "config_hash": self._config_hash(),
        }

    def _config_hash(self) -> str:
        import hashlib, json
        return hashlib.sha256(json.dumps(self.config, sort_keys=True).encode()).hexdigest()[:16]
''',
        "strategies/templates/__init__.py": "",
    }

    for path, content in templates.items():
        full_path = settings.project_root / path
        if full_path.exists() and not force:
            continue
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content)


def _setup_git_hooks(force: bool) -> None:
    """Configurar pre-commit hooks."""
    hook_content = """#!/bin/sh
# pre-commit hook para Trading Science Framework
# Ejecuta: ruff, mypy, pytest (unit), gov check en manifests

echo "🔍 Running pre-commit checks..."

# Ruff lint
ruff check . || exit 1

# MyPy type check
mypy tsf || exit 1

# Unit tests (fast)
pytest tests/unit -x -q || exit 1

# Governance check en manifests modificados
if git diff --cached --name-only | grep -q "research/artifacts/.*\\.json$"; then
    echo "🔒 Manifest modificado — ejecutando gov check..."
    for manifest in $(git diff --cached --name-only | grep "research/artifacts/.*\\.json$"); do
        gov check --manifest "$manifest" || exit 1
    done
fi

echo "✅ Pre-commit checks passed"
"""
    hook_path = settings.project_root / ".git" / "hooks" / "pre-commit"
    if hook_path.exists() and not force:
        return
    hook_path.parent.mkdir(parents=True, exist_ok=True)
    hook_path.write_text(hook_content)
    hook_path.chmod(0o755)


def _verify_installation() -> None:
    """Verificar que la toolchain está instalada."""
    import subprocess
    import sys

    required = [
        "purgedcv",
        "factor-qc",
        "falsification-ledger",
        "lookahead-free",
        "pit-adjuster",
        "lesson-book",
        "holdout-governance",
    ]

    missing = []
    for pkg in required:
        result = subprocess.run([sys.executable, "-c", f"import {pkg.replace('-', '_')}"],
                                capture_output=True)
        if result.returncode != 0:
            missing.append(pkg)

    if missing:
        console.print(f"[yellow]⚠️  Paquetes Holdout faltantes: {', '.join(missing)}[/yellow]")
        console.print("[dim]Instala con: pip install " + " ".join(missing) + "[/dim]")
    else:
        console.print("[green]✅ Toolchain Holdout completa instalada[/green]")


if __name__ == "__main__":
    app()