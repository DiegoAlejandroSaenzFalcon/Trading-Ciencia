"""
CLI Fase 1: Datos — Obtención, limpieza, PIT rebuild, quality gates.

Comandos:
- stream: Streaming OANDA en tiempo real
- fetch: Descarga histórica
- pit: Reconstrucción PIT (pit-adjuster)
- quality: Limpieza, auditoría, snapshots (ashare-data-immunity)
"""

import typer
from rich.console import Console

app = typer.Typer(name="data", help="Fase 1: Datos — Obtención, limpieza, PIT, quality gates", no_args_is_help=True)
console = Console()


@app.command(name="stream")
def stream_data(
    symbol: str = typer.Option("XAUUSD", "--symbol", "-s", help="Símbolo a streamear"),
    timeframe: str = typer.Option("M5", "--timeframe", "-t", help="Timeframe"),
    duration: int = typer.Option(60, "--duration", "-d", help="Duración en minutos (0=indefinido)"),
    output: str = typer.Option("data/raw/stream.jsonl", "--output", "-o", help="Archivo de salida"),
) -> None:
    """Streaming de precios en tiempo real desde OANDA."""
    console.print(f"[cyan]Iniciando stream: {symbol} {timeframe}[/cyan]")
    console.print("[yellow]No implementado aún — Fase 1 pendiente[/yellow]")
    # TODO: Implementar streaming OANDA v20 WebSocket


@app.command(name="fetch")
def fetch_historical(
    symbol: str = typer.Option("XAUUSD", "--symbol", "-s"),
    timeframe: str = typer.Option("M5", "--timeframe", "-t"),
    count: int = typer.Option(5000, "--count", "-c", help="Número de velas"),
    output: str = typer.Option("data/raw/historical.json", "--output", "-o"),
) -> None:
    """Descarga histórica desde OANDA REST API."""
    console.print(f"[cyan]Descargando {count} velas: {symbol} {timeframe}[/cyan]")
    console.print("[yellow]No implementado aún — Fase 1 pendiente[/yellow]")
    # TODO: Implementar fetch histórico OANDA v20 REST


@app.command(name="pit")
def pit_rebuild(
    bars: str = typer.Option("data/raw/bars.json", "--bars", "-b", help="Archivo de velas raw"),
    actions: str = typer.Option("data/raw/corporate_actions.json", "--actions", "-a", help="Archivo de corporate actions"),
    as_of: str = typer.Option("2026-09-05", "--as-of", help="Fecha corte (YYYY-MM-DD)"),
    code: str = typer.Option("XAUUSD", "--code", help="Código símbolo"),
    output: str = typer.Option("data/pit/hfq.json", "--output", "-o"),
) -> None:
    """Reconstrucción PIT hfq usando pit-adjuster."""
    console.print(f"[cyan]Reconstruyendo PIT para {code} al {as_of}[/cyan]")
    console.print("[yellow]No implementado aún — integra pit-adjuster CLI[/yellow]")
    # TODO: wrapper pit-adjuster rebuild


@app.command(name="pit-check")
def pit_checks(
    bars: str = typer.Option("data/pit/hfq.json", "--bars", "-b"),
    actions: str = typer.Option("data/raw/corporate_actions.json", "--actions", "-a"),
    as_of: str = typer.Option("2026-09-05", "--as-of"),
    live: str = typer.Option("data/raw/live_closes.json", "--live", help="Precios live para drift-check"),
) -> None:
    """Ejecuta invert-check y drift-check de pit-adjuster."""
    console.print("[cyan]Ejecutando validaciones PIT...[/cyan]")
    console.print("[yellow]No implementado aún — integra pit-adjuster CLI[/yellow]")
    # TODO: wrapper pit-adjuster invert-check, drift-check


@app.command(name="clean")
def clean_data(
    input_file: str = typer.Option("data/raw/bars.json", "--input", "-i"),
    output: str = typer.Option("data/pit/clean.json", "--output", "-o"),
    drop_non_positive: bool = typer.Option(False, "--drop-non-positive"),
) -> None:
    """Limpieza y validación OHLCV (ashare-data-immunity)."""
    console.print("[cyan]Limpiando y validando datos...[/cyan]")
    console.print("[yellow]No implementado aún — integra ashare-data-immunity CLI[/yellow]")


@app.command(name="audit")
def audit_data(
    watchlist: str = typer.Option("governance/watchlist.json", "--watchlist", "-w"),
    history_root: str = typer.Option("data/pit", "--history-root"),
    audit_root: str = typer.Option("data/audits", "--audit-root"),
) -> None:
    """Auditoría diaria de calidad (ashare-data-immunity)."""
    console.print("[cyan]Ejecutando auditoría de calidad...[/cyan]")
    console.print("[yellow]No implementado aún — integra ashare-data-immunity CLI[/yellow]")


@app.command(name="snapshot")
def snapshot_data(
    name: str = typer.Option("v2026-09-05", "--name", "-n"),
    cutoff: str = typer.Option("2026-09-05", "--cutoff"),
    files: str = typer.Option("data/pit/*.json", "--files", "-f"),
    root: str = typer.Option("data", "--root"),
    output: str = typer.Option("data/manifests/v1.json", "--output", "-o"),
) -> None:
    """Crear snapshot SHA-256 de datos (ashare-data-immunity)."""
    console.print(f"[cyan]Creando snapshot {name} con cutoff {cutoff}[/cyan]")
    console.print("[yellow]No implementado aún — integra ashare-data-immunity CLI[/yellow]")


@app.command(name="repair")
def repair_data(
    bars: str = typer.Option("data/pit/bars.json", "--bars", "-b"),
    corrections: str = typer.Option("data/corrections.json", "--corrections", "-c"),
    code: str = typer.Option("XAUUSD", "--code"),
    note: str = typer.Option("", "--note", help="Nota de procedencia"),
    log: str = typer.Option("data/repairs.jsonl", "--log"),
    output: str = typer.Option("data/pit/bars_fixed.json", "--output", "-o"),
) -> None:
    """Reparar datos con procedencia (ashare-data-immunity)."""
    console.print("[cyan]Reparando datos con procedencia...[/cyan]")
    console.print("[yellow]No implementado aún — integra ashare-data-immunity CLI[/yellow]")


if __name__ == "__main__":
    app()