"""Máquina de estados formal para Order (FSM)."""

from dataclasses import dataclass
from enum import Enum
from typing import FrozenSet


class OrderState(str, Enum):
    PENDING_VALIDATION = "pending_validation"
    VALIDATED = "validated"
    SUBMITTED = "submitted"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    REJECTED = "rejected"
    CANCEL_PENDING = "cancel_pending"
    CANCELLED = "cancelled"
    SETTLED = "settled"


VALID_TRANSITIONS: frozenset[tuple[OrderState, OrderState]] = frozenset({
    (OrderState.PENDING_VALIDATION, OrderState.VALIDATED),
    (OrderState.PENDING_VALIDATION, OrderState.REJECTED),
    (OrderState.VALIDATED, OrderState.SUBMITTED),
    (OrderState.VALIDATED, OrderState.REJECTED),
    (OrderState.SUBMITTED, OrderState.PARTIALLY_FILLED),
    (OrderState.SUBMITTED, OrderState.FILLED),
    (OrderState.SUBMITTED, OrderState.REJECTED),
    (OrderState.SUBMITTED, OrderState.CANCEL_PENDING),
    (OrderState.PARTIALLY_FILLED, OrderState.FILLED),
    (OrderState.PARTIALLY_FILLED, OrderState.CANCEL_PENDING),
    (OrderState.CANCEL_PENDING, OrderState.CANCELLED),
    (OrderState.CANCEL_PENDING, OrderState.FILLED),
    (OrderState.FILLED, OrderState.SETTLED),
    (OrderState.REJECTED, OrderState.SETTLED),
    (OrderState.CANCELLED, OrderState.SETTLED),
})


@dataclass(frozen=True)
class OrderStateMachine:
    """Validador de transiciones (inmutable, thread-safe)."""

    current_state: OrderState = OrderState.PENDING_VALIDATION

    def can_transition(self, next_state: OrderState) -> bool:
        return (self.current_state, next_state) in VALID_TRANSITIONS

    def transition(self, next_state: OrderState) -> "OrderStateMachine":
        if not self.can_transition(next_state):
            raise ValueError(
                f"Transición inválida: {self.current_state} → {next_state}. "
                f"Permitidas: {self.allowed_next()}"
            )
        return OrderStateMachine(current_state=next_state)

    def allowed_next(self) -> list[OrderState]:
        return [to for from_, to in VALID_TRANSITIONS if from_ == self.current_state]

    def is_terminal(self) -> bool:
        return self.current_state in {
            OrderState.FILLED,
            OrderState.REJECTED,
            OrderState.CANCELLED,
            OrderState.SETTLED,
        }
