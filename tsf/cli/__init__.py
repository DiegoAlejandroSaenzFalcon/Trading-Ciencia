"""
CLI principal del Trading Science Framework.

Comandos organizados por fase del proceso científico:
- data: obtención, limpieza, PIT, quality gates
- research: hipótesis, pipelines, pre-registro
- validate: backtesting honesto, CPCV, gates factor-qc
- execute: paper/live trading, risk management
- govern: manifests, release gates, CI
- learn: psychology, lesson-book, tuition memory
"""

import sys
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from ..config import settings

app = typer.Typer(
    name="tsf",
    help="Trading Science Framework — Marco de Investigación Científica Aplicada al Trading",
    add_completion=False,
    no_args_is_help=True,
    rich_markup_mode="rich",
)

console = Console()


def version_callback(value: bool) -> None:
    if value:
        from .. import __version__, __author__, __license__, __url__
        console.print(f"[bold cyan]Trading Science Framework[/bold cyan] v{__version__}")
        console.print(f"Author: {__author__} | License: {__license__}")
        console.print(f"URL: {__url__}")
        raise typer.Exit()


@app.callback()
def main(
    version: Optional[bool] = typer.Option(
        None, "--version", "-v", callback=version_callback, is_eager=True,
        help="Mostrar versión y salir"
    ),
    config_check: bool = typer.Option(
        False, "--check-config", help="Validar configuración y salir"
    ),
) -> None:
    """
    Trading Science Framework (TSF)

    Marco de investigación científica para trading:
    - Datos íntegros (PIT, quality gates)
    - Investigación honesta (pre-registro, falsificación)
    - Validación rigurosa (CPCV, DSR, PBO, MinTRL)
    - Ejecución controlada (risk management, gates)
    - Gobernanza de evidencia (manifests, release gates)
    - Psicología cuantificada (tuition memory)
    """
    if config_check:
        _check_config()
        raise typer.Exit()


def _check_config() -> None:
    """Validar configuración crítica."""
    console.print(Panel.fit(
        "[bold]Validando configuración TSF...[/bold]",
        border_style="cyan"
    ))

    issues = []
    warnings = []

    # Verificar OANDA
    if not settings.oanda.account_id or settings.oanda.account_id == "your-demo-account-id-here":
        issues.append("OANDA_ACCOUNT_ID no configurado")
    if not settings.oanda.api_key or settings.oanda.api_key == "your-demo-api-key-here":
        issues.append("OANDA_API_KEY no configurado")

    # Verificar directorios
    for name, path in [
        ("data", settings.data_dir),
        ("research", settings.research_dir),
        ("strategies", settings.strategies_dir),
        ("lessons", settings.lessons_dir),
        ("governance", settings.governance_dir),
        ("logs", settings.logs_dir),
    ]:
        if not path.exists():
            warnings.append(f"Directorio {name} no existe: {path}")

    # Verificar governance policy
    policy_path = Path(settings.governance.policy_path)
    if not policy_path.exists():
        warnings.append(f"Policy de gobernanza no existe: {policy_path}")

    # Resultados
    table = Table(title="Config Check Results", show_header=True)
    table.add_column("Componente", style="cyan")
    table.add_column("Estado", style="bold")
    table.add_column("Detalle", style="dim")

    if issues:
        for issue in issues:
            table.add_row("❌ CRÍTICO", "FALLO", issue)
    else:
        table.add_row("OANDA", "✅ OK", f"Account: {settings.oanda.account_id[:8]}...")

    for warning in warnings:
        table.add_row("⚠️  ADVERTENCIA", "AVISO", warning)

    if not issues and not warnings:
        table.add_row("TODO", "✅ OK", "Configuración válida")

    console.print(table)

    if issues:
        console.print("\n[bold red]Configuración inválida — corrige los errores críticos[/bold red]")
        sys.exit(1)
    elif warnings:
        console.print("\n[bold yellow]Configuración válida con advertencias[/bold yellow]")
    else:
        console.print("\n[bold green]Configuración completamente válida[/bold green]")


# Sub-comandos por fase
@app.command(name="data")
def data_cli() -> None:
    """Fase 1: Datos — Obtención, limpieza, PIT, quality gates."""
    from .data import app as data_app
    data_app()


@app.command(name="research")
def research_cli() -> None:
    """Fase 2: Investigación — Hipótesis, pipelines, pre-registro."""
    from .research import app as research_app
    research_app()


@app.command(name="validate")
def validate_cli() -> None:
    """Fase 3: Validación — Backtesting honesto, CPCV, gates factor-qc."""
    from .validation import app as validation_app
    validation_app()


@app.command(name="execute")
def execute_cli() -> None:
    """Fase 4: Ejecución — Paper/live trading, risk management."""
    from .execution import app as execution_app
    execution_app()


@app.command(name="govern")
def govern_cli() -> None:
    """Fase 5: Gobernanza — Manifests, release gates, CI."""
    from .governance import app as governance_app
    governance_app()


@app.command(name="learn")
def learn_cli() -> None:
    """Fase 6: Psicología — Tuition memory, lesson-book, premortems."""
    from .psychology import app as psychology_app
    psychology_app()


@app.command(name="demo")
def demo_cli(
    phase: int = typer.Option(0, "--phase", "-p", help="Ejecutar demo de fase específica (0=todas)"),
) -> None:
    """Ejecutar demos integrados de cada fase."""
    from .demo import run_demo
    run_demo(phase)


@app.command(name="init")
def init_cli(
    force: bool = typer.Option(False, "--force", "-f", help="Sobrescribir archivos existentes"),
) -> None:
    """Inicializar estructura completa del proyecto (directorios, configs, templates)."""
    from .init import initialize_project
    initialize_project(force)


if __name__ == "__main__":
    app()