"""Tests unitarios: IQOptionAdapterConfig."""

import pytest
from pydantic import ValidationError

from trading_otc.config import IQOptionAdapterConfig


class TestIQOptionAdapterConfig:
    def test_defaults(self):
        cfg = IQOptionAdapterConfig()
        assert cfg.rest_rps == 30
        assert cfg.ws_rps == 100
        assert cfg.demo is True
        assert cfg.ws_url == "wss://iqoption.com/echo/websocket"

    def test_custom_values(self):
        cfg = IQOptionAdapterConfig(rest_rps=10, demo=False, max_retries=5)
        assert cfg.rest_rps == 10
        assert cfg.demo is False
        assert cfg.max_retries == 5

    def test_validation_positive_rps(self):
        with pytest.raises(ValidationError):
            IQOptionAdapterConfig(rest_rps=0)

    def test_validation_positive_backoff(self):
        with pytest.raises(ValidationError):
            IQOptionAdapterConfig(base_backoff=-1.0)