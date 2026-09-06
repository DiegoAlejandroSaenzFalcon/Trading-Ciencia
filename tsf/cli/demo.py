"""
CLI Demos integrados por fase.

Ejecuta demos completos de cada fase para verificar instalación y entender el flujo.
"""

import typer
from rich.console import Console
from rich.panel import Panel

app = typer.Typer(name="demo", help="Demos integrados por fase", no_args_is_help=True)
console = Console()


def run_demo(phase: int = 0) -> None:
    """Ejecutar demo de fase específica (0 = todas)."""
    phases = {
        1: ("Fase 1: Datos", _demo_data),
        2: ("Fase 2: Investigación", _demo_research),
        3: ("Fase 3: Validación", _demo_validation),
        4: ("Fase 4: Ejecución", _demo_execution),
        5: ("Fase 5: Gobernanza", _demo_governance),
        6: ("Fase 6: Psicología", _demo_psychology),
    }

    if phase == 0:
        console.print(Panel.fit(
            "[bold]Ejecutando TODAS las demos secuencialmente[/bold]\n"
            "Esto verifica que la toolchain Holdout está instalada correctamente.",
            border_style="cyan"
        ))
        for p in range(1, 7):
            _run_single_phase(p, phases[p])
    elif phase in phases:
        _run_single_phase(phase, phases[phase])
    else:
        console.print(f"[red]Fase inválida: {phase}. Use 0-6.[/red]")
        raise typer.Exit(1)


def _run_single_phase(num: int, phase_info: tuple) -> None:
    name, func = phase_info
    console.print(Panel.fit(f"[bold]{name}[/bold]", border_style="green"))
    try:
        func()
        console.print(f"[green]✅ {name} completada[/green]\n")
    except Exception as e:
        console.print(f"[red]❌ {name} falló: {e}[/red]\n")
        raise


def _demo_data() -> None:
    """Demo Fase 1: Toolchain Holdout data tools."""
    import subprocess
    import sys

    tools = [
        ("purgedcv", ["python", "-m", "purgedcv.examples.demo"]),
        ("ashare-data-immunity", ["python", "-m", "ashare_data_immunity.examples.demo"]),
    ]
    for name, cmd in tools:
        console.print(f"  [dim]Ejecutando {name} demo...[/dim]")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            console.print(f"  [yellow]{name} demo falló (esperado si no hay datos A-share)[/yellow]")
        else:
            console.print(f"  [green]{name} demo OK[/green]")


def _demo_research() -> None:
    """Demo Fase 2: Falsification ledger."""
    import subprocess

    console.print("  [dim]Ejecutando falsification-ledger demo...[/dim]")
    result = subprocess.run(["python", "-m", "falsification_ledger.examples.demo"], capture_output=True, text=True, timeout=60)
    if result.returncode == 0:
        console.print("  [green]falsification-ledger demo OK[/green]")
    else:
        console.print("  [yellow]falsification-ledger demo falló[/yellow]")


def _demo_validation() -> None:
    """Demo Fase 3: Factor-qc gate."""
    import subprocess

    console.print("  [dim]Ejecutando factor-qc demo...[/dim]")
    result = subprocess.run(["python", "-m", "factor_qc.examples.demo"], capture_output=True, text=True, timeout=60)
    if result.returncode == 0:
        console.print("  [green]factor-qc demo OK[/green]")
    else:
        console.print("  [yellow]factor-qc demo falló[/yellow]")


def _demo_execution() -> None:
    """Demo Fase 4: OANDA connectivity test."""
    console.print("  [dim]Test de conectividad OANDA (requiere .env configurado)...[/dim]")
    console.print("  [yellow]No implementado — configura .env y prueba manualmente[/yellow]")


def _demo_governance() -> None:
    """Demo Fase 5: Holdout-governance end-to-end."""
    import subprocess
    import os

    demo_path = "examples/gov-demo"
    if os.path.exists(demo_path):
        console.print(f"  [dim]Ejecutando gov-demo en {demo_path}...[/dim]")
        result = subprocess.run(["./run-demo.sh"], cwd=demo_path, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            console.print("  [green]gov-demo OK (green path → tamper → red path → restore)[/green]")
        else:
            console.print("  [yellow]gov-demo falló (verificar instalación Holdout tools)[/yellow]")
    else:
        console.print("  [yellow]gov-demo no encontrado — clonar holdout-governance examples[/yellow]")


def _demo_psychology() -> None:
    """Demo Fase 6: Lesson-book."""
    import subprocess

    console.print("  [dim]Ejecutando lesson-book demo...[/dim]")
    result = subprocess.run(["python", "-m", "lesson_book.examples.demo"], capture_output=True, text=True, timeout=60)
    if result.returncode == 0:
        console.print("  [green]lesson-book demo OK[/green]")
    else:
        console.print("  [yellow]lesson-book demo falló[/yellow]")


if __name__ == "__main__":
    app()