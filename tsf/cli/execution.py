"""
CLI Fase 4: Ejecución — Paper/live trading, risk management.

Comandos:
- paper: Paper trading en demo OANDA
- live: Live trading (SOLO tras validación demo extensiva + approve humano)
- risk: Calcular sizing, verificar breakers
- reconcile: Reconciliar estado broker ↔ DB
"""

import typer
from rich.console import Console

app = typer.Typer(name="execute", help="Fase 4: Ejecución — Paper/live trading, risk management", no_args_is_help=True)
console = Console()


@app.command(name="paper")
def paper_trade(
    strategy: str = typer.Option(..., "--strategy", "-s", help="Path a estrategia (Python module)"),
    duration_days: int = typer.Option(30, "--days", "-d", help="Días de paper trading"),
    dry_run: bool = typer.Option(True, "--dry-run/--no-dry-run", help="Simulación sin órdenes reales"),
    config: str = typer.Option("config/paper.yaml", "--config", "-c"),
) -> None:
    """
    Paper trading en cuenta demo OANDA.

    Requisitos previos:
    - Estrategia validada por factor-qc gate (exit 0)
    - Pre-registrada en falsification-ledger
    - Configuración risk management conservadora
    """
    console.print(f"[cyan]Iniciando paper trading: {strategy} por {duration_days} días[/cyan]")
    console.print(f"[yellow]Dry-run: {dry_run}[/yellow]")
    console.print("[yellow]No implementado aún — motor de ejecución pendiente[/yellow]")


@app.command(name="live")
def live_trade(
    strategy: str = typer.Option(..., "--strategy", "-s"),
    config: str = typer.Option("config/live.yaml", "--config", "-c"),
    human_approval: bool = typer.Option(False, "--approved", help="Confirmar aprobación humana explícita"),
) -> None:
    """
    Live trading con capital real.

    ⚠️  SOLO EJECUTAR SI:
    1. Paper trading ≥ 60 días con resultados consistentes
    2. factor-qc gate PASS (exit 0) en OOS reciente
    3. falsification-ledger adjudicado "support" con hit-rate > baseline
    4. Aprobación humana explícita (--approved)
    5. Capital que puedes permitirte perder 100%
    """
    if not human_approval:
        console.print("[bold red]ERROR: Live trading requiere --approved (aprobación humana explícita)[/bold red]")
        console.print("[dim]Esto no es un juego. Tu capital está en juego.[/dim]")
        raise typer.Exit(1)

    console.print(f"[bold red]⚠️  LIVE TRADING ACTIVADO: {strategy}[/bold red]")
    console.print("[yellow]No implementado aún — motor de ejecución pendiente[/yellow]")


@app.command(name="risk")
def risk_check(
    equity: float = typer.Option(..., "--equity", "-e", help="Equity actual"),
    sl_distance: float = typer.Option(..., "--sl", help="Distancia SL en puntos"),
    atr: float = typer.Option(..., "--atr", help="ATR actual"),
    symbol: str = typer.Option("XAUUSD", "--symbol"),
    config: str = typer.Option("config/risk.yaml", "--config"),
) -> None:
    """Calcular sizing y verificar breakers pre-trade."""
    console.print(f"[cyan]Risk check: equity={equity}, sl={sl_distance}, atr={atr}[/cyan]")
    console.print("[yellow]No implementado aún — RiskManager class pendiente[/yellow]")


@app.command(name="reconcile")
def reconcile_state(
    account_id: str = typer.Option(..., "--account"),
    db_path: str = typer.Option("data/tsf.db", "--db"),
) -> None:
    """Reconciliar posiciones/órdenes broker ↔ base de datos."""
    console.print("[cyan]Reconciliando estado broker ↔ DB...[/cyan]")
    console.print("[yellow]No implementado aún[/yellow]")


@app.command(name="orders")
def manage_orders(
    action: str = typer.Option(..., "--action", help="list/open/close/modify/cancel"),
    order_id: str = typer.Option(None, "--order-id"),
    symbol: str = typer.Option("XAUUSD", "--symbol"),
) -> None:
    """Gestión manual de órdenes (emergencia/supervisión)."""
    console.print(f"[cyan]Gestión órdenes: {action}[/cyan]")
    console.print("[yellow]No implementado aún[/yellow]")


if __name__ == "__main__":
    app()