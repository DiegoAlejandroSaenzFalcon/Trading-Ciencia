"""
CLI Fase 3: Validación — Backtesting honesto, CPCV, gates factor-qc.

Comandos:
- cpcv: Ejecutar Combinatorial Purged CV
- metrics: Calcular DSR, PSR, PBO, MinTRL, Haircut
- gate: Ejecutar factor-qc gate (fail-closed)
- audit: Auditoría de leakage, embargo, overfitting
"""

import typer
from rich.console import Console

app = typer.Typer(name="validate", help="Fase 3: Validación — Backtesting honesto, CPCV, gates factor-qc", no_args_is_help=True)
console = Console()


@app.command(name="cpcv")
def run_cpcv(
    returns: str = typer.Option(..., "--returns", "-r", help="Path a returns JSON (lista de retornos por período)"),
    trials: str = typer.Option(..., "--trials", "-t", help="Path a trials matrix JSON (T x N)"),
    n_splits: int = typer.Option(12, "--n-splits", help="N groups para CPCV"),
    n_test_groups: int = typer.Option(6, "--n-test-groups", help="K test groups"),
    output: str = typer.Option("research/backtests/cpcv_results.json", "--output", "-o"),
) -> None:
    """
    Ejecutar Combinatorial Purged CV (CPCV).

    Genera C(N,K) folds → paths OOS → métricas por path.
    Esta es la ÚNICA forma honesta de validar estrategias en series temporales.
    """
    console.print(f"[cyan]Ejecutando CPCV: N={n_splits}, K={n_test_groups}[/cyan]")
    console.print("[yellow]No implementado aún — integra purgedcv:[/yellow]")
    console.print("[dim]from purgedcv import CombinatorialPurgedCV, reconstruct_paths, path_metrics[/dim]")


@app.command(name="metrics")
def calculate_metrics(
    returns: str = typer.Option(..., "--returns", "-r", help="Returns del candidato seleccionado"),
    trials: str = typer.Option(..., "--trials", "-t", help="Matriz de TODOS los trials (T x N)"),
    n_trials: int = typer.Option(..., "--n-trials", help="NÚMERO HONESTO de configuraciones probadas"),
    periods_per_year: int = typer.Option(252, "--periods"),
    output: str = typer.Option("research/backtests/metrics.json", "--output", "-o"),
) -> None:
    """
    Calcular métricas honestas: DSR, PSR, PBO, MinTRL, Haircut Sharpe.

    n_trials DEBE ser el número real de configuraciones que probaste.
    Si mientes aquí, el gate factor-qc te bloqueará (o te auto-engañarás).
    """
    console.print(f"[cyan]Calculando métricas con n_trials={n_trials}[/cyan]")
    console.print("[yellow]No implementado aún — integra purgedcv:[/yellow]")
    console.print("[dim]from purgedcv import deflated_sharpe_ratio, probabilistic_sharpe_ratio, probability_of_backtest_overfitting, min_track_record_length[/dim]")


@app.command(name="gate")
def factor_qc_gate(
    returns: str = typer.Option(..., "--returns", "-r", help="Returns del candidato"),
    trials: str = typer.Option(..., "--trials", "-t", help="Matriz trials"),
    n_trials: int = typer.Option(..., "--n-trials", help="Número honesto de trials"),
    periods_per_year: int = typer.Option(252, "--periods"),
    n_blocks: int = typer.Option(16, "--n-blocks", help="Granularidad CSCV para PBO"),
    output: str = typer.Option("research/backtests/gate_result.json", "--output", "-o"),
) -> None:
    """
    Ejecutar factor-qc gate (FAIL-CLOSED).

    Exit codes: 0=pass (no P0), 1=P0 blocker, 2=usage error.
    P0 blockers: DSR < threshold, PBO > threshold, Haircut < floor, MinTRL > sample.
    """
    console.print(f"[cyan]Ejecutando factor-qc gate con n_trials={n_trials}[/cyan]")
    console.print("[yellow]No implementado aún — integra factor-qc CLI:[/yellow]")
    console.print("[dim]qc check --returns returns.json --trials trials.json --n-trials 247[/dim]")


@app.command(name="audit")
def audit_backtest(
    returns: str = typer.Option(..., "--returns", "-r"),
    trials: str = typer.Option(..., "--trials", "-t"),
    output: str = typer.Option("research/backtests/audit.json", "--output", "-o"),
) -> None:
    """Auditoría completa: leakage, embargo, selection bias, overfitting."""
    console.print("[cyan]Ejecutando auditoría de backtest...[/cyan]")
    console.print("[yellow]No implementado aún — integra purgedcv diagnostics[/dim]")


@app.command(name="walkforward")
def walkforward_validation(
    returns: str = typer.Option(..., "--returns", "-r"),
    n_splits: int = typer.Option(10, "--n-splits"),
    test_size: int = typer.Option(252, "--test-size"),
    window: str = typer.Option("expanding", "--window", help="expanding/sliding"),
    purge_horizon: str = typer.Option("1D", "--purge"),
    output: str = typer.Option("research/backtests/wf_results.json", "--output", "-o"),
) -> None:
    """Walk-forward validation (alternativa a CPCV para series más cortas)."""
    console.print("[cyan]Ejecutando Walk-Forward Validation...[/cyan]")
    console.print("[yellow]No implementado aún — integra purgedcv WalkForwardSplit[/dim]")


if __name__ == "__main__":
    app()