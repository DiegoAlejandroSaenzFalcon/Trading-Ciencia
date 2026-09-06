"""
CLI Fase 2: Investigación — Hipótesis, pipelines, pre-registro.

Comandos:
- hypothesize: Crear hipótesis falsable estructurada
- pipeline: Diseñar pipeline verificable (lookahead-free)
- preregister: Pre-registrar hipótesis + kill criteria (falsification-ledger)
- submit: Enviar evidencia de falsificación
- adjudicate: Adjudicar resultado honesto
- report: Reporte hit-rate vs baseline
"""

import json
from pathlib import Path
from datetime import datetime
from typing import Optional

import typer
from rich.console import Console
from rich.table import Table

from ..config import settings

app = typer.Typer(name="research", help="Fase 2: Investigación — Hipótesis, pipelines, pre-registro", no_args_is_help=True)
console = Console()


@app.command(name="hypothesize")
def create_hypothesis(
    name: str = typer.Option(..., "--name", "-n", help="Nombre único de la hipótesis"),
    description: str = typer.Option(..., "--description", "-d", help="Descripción clara y falsable"),
    expected_direction: str = typer.Option(..., "--direction", help="long/short/neutral"),
    kill_criteria: str = typer.Option(..., "--kill", help="Qué evidencia MATA la hipótesis (JSON o path)"),
    source_type: str = typer.Option("pipeline", "--source", help="paper/business/cross_domain/pipeline/other"),
    output: Optional[str] = typer.Option(None, "--output", "-o", help="Archivo salida (default: research/hypotheses/{name}.json)"),
) -> None:
    """
    Crear hipótesis falsable estructurada.

    Una hipótesis científica DEBE especificar qué evidencia la refutaría.
    Si no puedes decir qué te haría cambiar de opinión, no es ciencia.
    """
    output_path = Path(output or settings.research_dir / "hypotheses" / f"{name}.json")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Parsear kill_criteria
    if Path(kill_criteria).exists():
        with open(kill_criteria) as f:
            kill_data = json.load(f)
    else:
        try:
            kill_data = json.loads(kill_criteria)
        except json.JSONDecodeError:
            console.print("[red]kill_criteria debe ser JSON válido o path a archivo JSON[/red]")
            raise typer.Exit(1)

    hypothesis = {
        "schema_version": "tsf.hypothesis.v1",
        "hypothesis_id": name,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "description": description,
        "expected_direction": expected_direction,
        "source_type": source_type,
        "falsification_contract": kill_data,
        "status": "draft",  # draft -> preregistered -> tested -> adjudicated
        "metadata": {
            "author": "Diego Alejandro Saenz Falcon",
            "framework_version": "0.1.0",
        }
    }

    with open(output_path, "w") as f:
        json.dump(hypothesis, f, indent=2, ensure_ascii=False)

    console.print(f"[green]✅ Hipótesis creada: {output_path}[/green]")
    console.print(f"[dim]Ahora pre-regístrala con: tsf research preregister --hypothesis {output_path}[/dim]")


@app.command(name="pipeline")
def design_pipeline(
    name: str = typer.Option(..., "--name", "-n", help="Nombre del pipeline"),
    hypothesis: str = typer.Option(..., "--hypothesis", "-h", help="Path a hipótesis JSON"),
    output: Optional[str] = typer.Option(None, "--output", "-o", help="Archivo salida pipeline JSON"),
) -> None:
    """
    Diseñar pipeline verificable (formato lookahead-free).

    Define: reads (con release_time), windows (con window_end),
    pit_reads (con read_cutoff), decisions (con decision_time).
    """
    console.print(f"[cyan]Diseñando pipeline para hipótesis: {hypothesis}[/cyan]")
    console.print("[yellow]No implementado aún — genera JSON lookahead-free manualmente[/yellow]")
    console.print("[dim]Ver: https://github.com/holdout-labs/lookahead-free#pipeline-format[/dim]")


@app.command(name="preregister")
def preregister_hypothesis(
    hypothesis: str = typer.Option(..., "--hypothesis", "-h", help="Path a hipótesis JSON"),
    verdict: str = typer.Option("support", "--verdict", help="support/against/uncertain"),
    reason: str = typer.Option(..., "--reason", "-r", help="Razonamiento del pre-registro"),
    state_dir: str = typer.Option("governance/ledger", "--state-dir"),
) -> None:
    """
    Pre-registrar hipótesis en falsification-ledger (hash-chain inmutable).

    Esto congela tu expectativa ANTES de ver cualquier evidencia OOS.
    """
    console.print(f"[cyan]Pre-registrando hipótesis en {state_dir}[/cyan]")
    console.print("[yellow]No implementado aún — integra falsification-ledger CLI:[/yellow]")
    console.print("[dim]fl preregister --case-id ... --verdict ... --reason ... --contract ...[/dim]")


@app.command(name="submit")
def submit_evidence(
    report: str = typer.Option(..., "--report", "-r", help="Path a falsification report JSON"),
    state_dir: str = typer.Option("governance/ledger", "--state-dir"),
) -> None:
    """Enviar reporte de falsificación (evidencia independiente) al ledger."""
    console.print("[cyan]Enviando evidencia al ledger...[/cyan]")
    console.print("[yellow]No implementado aún — integra falsification-ledger CLI: fl submit[/dim]")


@app.command(name="adjudicate")
def adjudicate_hypothesis(
    case_id: str = typer.Option(..., "--case-id", "-c", help="ID del caso pre-registrado"),
    verdict: str = typer.Option(..., "--verdict", help="support/against/uncertain"),
    state_dir: str = typer.Option("governance/ledger", "--state-dir"),
) -> None:
    """
    Adjudicar resultado honesto (una sola vez por caso).

    Aquí es donde la honestidad duele: si la evidencia dice "against",
    DEBES poner "against". No hay vuelta atrás.
    """
    console.print(f"[cyan]Adjudicando caso {case_id} con veredicto: {verdict}[/cyan]")
    console.print("[yellow]No implementado aún — integra falsification-ledger CLI: fl adjudicate[/dim]")


@app.command(name="report")
def hit_rate_report(
    state_dir: str = typer.Option("governance/ledger", "--state-dir"),
    min_cases: int = typer.Option(20, "--min-cases"),
) -> None:
    """Reporte de hit-rate vs baseline aleatorio (Wilson 95% CI)."""
    console.print("[cyan]Generando reporte de hit-rate...[/cyan]")
    console.print("[yellow]No implementado aún — integra falsification-ledger CLI: fl report[/dim]")


@app.command(name="verify")
def verify_ledger(
    state_dir: str = typer.Option("governance/ledger", "--state-dir"),
) -> None:
    """Verificar integridad hash-chain del ledger (detecta manipulaciones)."""
    console.print("[cyan]Verificando integridad hash-chain...[/cyan]")
    console.print("[yellow]No implementado aún — integra falsification-ledger CLI: fl verify[/dim]")


if __name__ == "__main__":
    app()