"""
CLI Fase 5: Gobernanza — Manifests, release gates, CI integration.

Comandos:
- init: Scaffold proyecto de investigación
- check: Ejecutar chain completa de gates (data → timing → backtest → falsify)
- validate: Validar manifest contra schema
- report: Reporte humano legible
- attach: Adjuntar evidencia a manifest
- health: Verificar integridad ledger
"""

import typer
from rich.console import Console

app = typer.Typer(name="govern", help="Fase 5: Gobernanza — Manifests, release gates, CI", no_args_is_help=True)
console = Console()


@app.command(name="init")
def init_research(
    dir: str = typer.Option("research/my-study", "--dir", "-d", help="Directorio del proyecto"),
    name: str = typer.Option(..., "--name", "-n", help="Nombre del estudio"),
    template: str = typer.Option("research_conclusion", "--template", help="research_conclusion/strategy_advice/public_copy"),
) -> None:
    """
    Scaffold estructura de investigación con manifest, policy, gate-inputs.
    """
    console.print(f"[cyan]Inicializando investigación: {name} en {dir}[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov init[/dim]")


@app.command(name="check")
def check_gates(
    manifest: str = typer.Option("research/artifact.json", "--manifest", "-m"),
    policy: str = typer.Option("governance/policy.yml", "--policy", "-p"),
) -> None:
    """
    Ejecutar chain completa de gates:
    1. data_integrity (ashare-data-immunity / pit-adjuster)
    2. timing (lookahead-free)
    3. statistical_quality (factor-qc)
    4. falsification (falsification-ledger)

    Exit: 0=release, 1=review_needed, 2=block
    """
    console.print(f"[cyan]Ejecutando gate chain sobre {manifest}[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov check[/dim]")


@app.command(name="validate")
def validate_manifest(
    manifest: str = typer.Option("research/artifact.json", "--manifest", "-m"),
    schema: str = typer.Option("schema/artifact.schema.json", "--schema"),
) -> None:
    """Validar manifest contra schema JSON (fail-closed)."""
    console.print("[cyan]Validando manifest...[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov validate[/dim]")


@app.command(name="report")
def generate_report(
    manifest: str = typer.Option("research/artifact.json", "--manifest", "-m"),
    output: str = typer.Option("research/report.md", "--output", "-o"),
) -> None:
    """Generar reporte humano legible del manifest y gates."""
    console.print("[cyan]Generando reporte...[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov report[/dim]")


@app.command(name="attach")
def attach_evidence(
    manifest: str = typer.Option("research/artifact.json", "--manifest", "-m"),
    gate: str = typer.Option(..., "--gate", help="data_integrity/timing/statistical_quality/falsification"),
    status: str = typer.Option(..., "--status", help="pass/fail/refuse"),
    tool: str = typer.Option(..., "--tool", help="imm/padj/lf/fl/qc"),
    report_ref: str = typer.Option(..., "--report-ref", help="sha256: del output de la tool"),
) -> None:
    """Adjuntar evidencia a manifest antes de check (resetea decision a pending)."""
    console.print(f"[cyan]Adjuntando evidencia a gate {gate}: {status}[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov attach[/dim]")


@app.command(name="health")
def ledger_health(
    ledger: str = typer.Option("governance/ledger.jsonl", "--ledger"),
) -> None:
    """Verificar salud del ledger (hash-chain, duplicates, timestamps)."""
    console.print("[cyan]Verificando salud del ledger...[/cyan]")
    console.print("[yellow]No implementado aún — integra holdout-governance CLI: gov health[/dim]")


@app.command(name="api")
def start_api(
    port: int = typer.Option(8000, "--port"),
    host: str = typer.Option("127.0.0.1", "--host"),
) -> None:
    """Iniciar API HTTP JSON para integración con agentes."""
    console.print(f"[cyan]Iniciando gov API en {host}:{port}[/cyan]")
    console.print("[yellow]No implementado aún — gov api[/dim]")


@app.command(name="mcp")
def start_mcp() -> None:
    """Iniciar servidor MCP (stdio) para Claude/Cursor/agentes."""
    console.print("[cyan]Iniciando gov MCP server...[/cyan]")
    console.print("[yellow]No implementado aún — gov mcp[/dim]")


if __name__ == "__main__":
    app()