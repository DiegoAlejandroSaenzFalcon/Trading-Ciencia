"""Job de reconciliación periódica (cron 30s)."""

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Protocol

logger = logging.getLogger(__name__)


class IOrderStore(Protocol):
    async def get_open_orders(self) -> list[str]: ...
    async def get_order(self, order_id: str) -> dict | None: ...
    async def update_order(self, order_id: str, data: dict) -> None: ...


class IBrokerClient(Protocol):
    async def check_order(self, broker_order_id: str) -> dict: ...
    async def get_orders_history(self, limit: int = 100) -> list[dict]: ...


@dataclass
class ReconciliationResult:
    checked: int = 0
    corrected: int = 0
    drifted: int = 0
    errors: int = 0
    duration_ms: float = 0.0


class ReconciliationJob:
    """Reconcilia estado local vs broker cada interval segundos."""

    def __init__(
        self,
        order_store: IOrderStore,
        broker_client: IBrokerClient,
        interval: float = 30.0,
    ):
        self._order_store = order_store
        self._broker = broker_client
        self._interval = interval
        self._task: asyncio.Task | None = None
        self._running = False

    async def start(self) -> None:
        if self._running:
            return
        self._running = True
        self._task = asyncio.create_task(self._run_loop())
        logger.info("ReconciliationJob iniciado (interval=%.1fs)", self._interval)

    async def stop(self) -> None:
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("ReconciliationJob detenido")

    async def _run_loop(self) -> None:
        while self._running:
            start = datetime.utcnow()
            try:
                await self._reconcile_once()
            except Exception as e:
                logger.exception("Error en reconciliación: %s", e)
            finally:
                elapsed = (datetime.utcnow() - start).total_seconds()
                sleep_time = max(0.1, self._interval - elapsed)
                await asyncio.sleep(sleep_time)

    async def _reconcile_once(self) -> ReconciliationResult:
        result = ReconciliationResult()

        open_order_ids = await self._order_store.get_open_orders()
        for order_id in open_order_ids:
            local_order = await self._order_store.get_order(order_id)
            if not local_order or not local_order.get("broker_order_id"):
                continue

            result.checked += 1
            try:
                broker_status = await self._broker.check_order(local_order["broker_order_id"])
                await self._merge_status(local_order, broker_status, result)
            except Exception as e:
                logger.warning("Fallo check order %s: %s", order_id, e)
                result.errors += 1

        try:
            history = await self._broker.get_orders_history(limit=200)
            for bro in history:
                if bro.get("id") not in open_order_ids:
                    result.drifted += 1
                    logger.warning("Orden huérfana detectada: %s", bro)
        except Exception as e:
            logger.warning("Fallo history scan: %s", e)

        return result

    async def _merge_status(self, local: dict, broker: dict, result: ReconciliationResult) -> None:
        broker_state = self._map_broker_status(broker)
        local_state = local.get("status")

        if broker_state != local_state:
            updates = {
                "status": broker_state,
                "fill_price": broker.get("price"),
                "fill_amount": broker.get("amount"),
                "profit": broker.get("profit"),
                "updated_at": datetime.utcnow().isoformat(),
            }
            await self._order_store.update_order(local["id"], updates)
            result.corrected += 1
            logger.info("Drift corregido: %s %s → %s", local["id"], local_state, broker_state)

    @staticmethod
    def _map_broker_status(broker: dict) -> str:
        status = broker.get("status", "").lower()
        if status in ("won", "win", "filled"):
            return "filled"
        if status in ("lost", "loss"):
            return "filled"
        if status in ("cancelled", "canceled"):
            return "cancelled"
        if status in ("pending", "open", "submitted"):
            return "submitted"
        return "rejected"
