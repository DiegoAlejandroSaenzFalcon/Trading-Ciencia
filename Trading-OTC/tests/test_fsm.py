"""Tests unitarios: OrderStateMachine (FSM formal)."""

import pytest

from trading_otc.fsm import (
    VALID_TRANSITIONS,
    OrderState,
    OrderStateMachine,
)


class TestOrderStateMachine:
    def test_initial_state(self):
        fsm = OrderStateMachine()
        assert fsm.current_state == OrderState.PENDING_VALIDATION

    def test_valid_transition_pending_to_validated(self):
        fsm = OrderStateMachine(OrderState.PENDING_VALIDATION)
        assert fsm.can_transition(OrderState.VALIDATED)
        fsm2 = fsm.transition(OrderState.VALIDATED)
        assert fsm2.current_state == OrderState.VALIDATED

    def test_invalid_transition_raises(self):
        fsm = OrderStateMachine(OrderState.PENDING_VALIDATION)
        with pytest.raises(ValueError):
            fsm.transition(OrderState.FILLED)

    def test_all_expected_transitions_covered(self):
        expected = {
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
        }
        assert expected.issubset(VALID_TRANSITIONS)

    def test_terminal_states(self):
        # Solo SETTLED no tiene transiciones de salida (true terminal)
        fsm_settled = OrderStateMachine(OrderState.SETTLED)
        assert fsm_settled.is_terminal()
        assert fsm_settled.allowed_next() == []

        # FILLED, REJECTED, CANCELLED tienen transición a SETTLED
        for state in [OrderState.FILLED, OrderState.REJECTED, OrderState.CANCELLED]:
            fsm = OrderStateMachine(state)
            assert fsm.is_terminal()  # is_terminal() los considera terminales
            assert fsm.allowed_next() == [OrderState.SETTLED]  # Pero tienen transición

    def test_chain_validated_to_filled(self):
        fsm = OrderStateMachine(OrderState.PENDING_VALIDATION)
        fsm = fsm.transition(OrderState.VALIDATED)
        fsm = fsm.transition(OrderState.SUBMITTED)
        fsm = fsm.transition(OrderState.FILLED)
        fsm = fsm.transition(OrderState.SETTLED)
        assert fsm.current_state == OrderState.SETTLED
        assert fsm.is_terminal()