"""
CLI Fase 6: Psicología — Tuition memory, lesson-book, premortems.

Comandos:
- add: Registrar error/lección con coste real
- match: Buscar lecciones relevantes ANTES de actuar (premortem automatizado)
- review: Revisión diaria de coste de tuition
- import: Importar knowledge base markdown
- stats: Estadísticas de patrones de error
"""

import typer
from rich.console import Console
from rich.table import Table

app = typer.Typer(name="learn", help="Fase 6: Psicología — Tuition memory, lesson-book, premortems", no_args_is_help=True)
console = Console()


@app.command(name="add")
def add_lesson(
    title: str = typer.Option(..., "--title", "-t", help="Título descriptivo"),
    issue: str = typer.Option(..., "--issue", help="Tipo: execution_without_action_plan/execution_failed/other"),
    error_category: str = typer.Option(None, "--category", "-c", help="price_limit/trading_time_closed/receipt_reader_error/other"),
    date: str = typer.Option(None, "--date", "-d", help="YYYY-MM-DD (default: hoy)"),
    code: str = typer.Option(None, "--code", help="Símbolo (XAUUSD, etc.)"),
    industry: str = typer.Option(None, "--industry", help="Sector/tipo mercado"),
    volatility: float = typer.Option(None, "--volatility", "-v", help="Volatilidad del día"),
    tags: str = typer.Option("", "--tags", help="Tags separados por coma: gap,limit-up,revenge"),
    cost: float = typer.Option(..., "--cost", help="Coste real en USD (tuition pagada)"),
    lesson: str = typer.Option(..., "--lesson", "-l", help="Lección aprendida (acción concreta)"),
    situation: str = typer.Option("", "--situation", help="Contexto narrativo"),
    book: str = typer.Option("lessons/book.jsonl", "--book", "-b"),
) -> None:
    """
    Registrar error/lección con coste real (tuition memory).

    Clasificación automática via rule table:
    - execution_failed + price_limit → price_limit_rejected (P1)
    - execution_without_action_plan → planning_gap (P1)
    - Sin clasificar → unclassified (P2, review manual)

    La regla es determinista: mismo input → misma clasificación, siempre.
    """
    console.print(f"[cyan]Registrando lección: {title} (cost: ${cost})[/cyan]")
    console.print("[yellow]No implementado aún — integra lesson-book CLI: lb add[/dim]")


@app.command(name="match")
def match_lessons(
    code: str = typer.Option(None, "--code"),
    industry: str = typer.Option(None, "--industry"),
    volatility: float = typer.Option(None, "--volatility"),
    tags: str = typer.Option("", "--tags"),
    market_cap: str = typer.Option(None, "--market-cap"),
    book: str = typer.Option("lessons/book.jsonl", "--book"),
    fail_closed: bool = typer.Option(True, "--fail-closed/--no-fail-closed", help="Exit 1 si no hay matches"),
) -> None:
    """
    Buscar lecciones relevantes ANTES de actuar (premortem automatizado).

    Scoring determinista:
    - same code: +3.0
    - same industry: +2.0
    - same market cap: +1.0
    - volatility proximity: up to +1.5
    - tag overlap: +0.5/tag (max +1.5)

    Requiere match primario (code/industry/market cap) para score > 0.
    """
    console.print("[cyan]Buscando lecciones relevantes para situación actual...[/cyan]")
    console.print("[yellow]No implementado aún — integra lesson-book CLI: lb match[/dim]")


@app.command(name="review")
def daily_review(
    date: str = typer.Option(None, "--date", "-d", help="YYYY-MM-DD (default: hoy)"),
    book: str = typer.Option("lessons/book.jsonl", "--book"),
    output: str = typer.Option("lessons/reviews/", "--output", "-o"),
) -> None:
    """
    Revisión diaria: cartas agrupadas por categoría/prioridad, coste total, markdown output.
    """
    console.print(f"[cyan]Generando revisión diaria para {date or 'hoy'}[/cyan]")
    console.print("[yellow]No implementado aún — integra lesson-book CLI: lb review[/dim]")


@app.command(name="import")
def import_lessons(
    source: str = typer.Option(..., "--from", "-f", help="Archivo markdown con headers ## y metadata **Field:**"),
    book: str = typer.Option("lessons/book.jsonl", "--book", "-b"),
) -> None:
    """
    Importar knowledge base markdown existente.

    Formato esperado:
    ## Título de la lección
    **Code:** XAUUSD
    **Industry:** forex
    **Volatility:** 0.03
    **Tags:** gap, limit-up
    **Cost:** 1200
    **Lesson:** never chase the open gap...
    """
    console.print(f"[cyan]Importando lecciones desde {source}[/cyan]")
    console.print("[yellow]No implementado aún — integra lesson-book CLI: lb import-lessons[/dim]")


@app.command(name="stats")
def lesson_stats(
    book: str = typer.Option("lessons/book.jsonl", "--book"),
    days: int = typer.Option(30, "--days"),
) -> None:
    """Estadísticas de patrones de error: frecuencia, coste total, top categories."""
    console.print("[cyan]Estadísticas de tuition memory...[/cyan]")
    console.print("[yellow]No implementado aún[/dim]")


@app.command(name="premortem")
def premortem_check(
    code: str = typer.Option(..., "--code"),
    volatility: float = typer.Option(..., "--volatility"),
    tags: str = typer.Option("", "--tags"),
    book: str = typer.Option("lessons/book.jsonl", "--book"),
) -> None:
    """
    Premortem automatizado: ejecuta match + review + alerta si hay matches P1.

    Úsalo como hook pre-trade: si exit code 1 → NO operar hasta revisar.
    """
    console.print("[cyan]Ejecutando premortem pre-trade...[/cyan]")
    console.print("[yellow]No implementado aún — wrapper sobre lb match + review[/dim]")


if __name__ == "__main__":
    app()