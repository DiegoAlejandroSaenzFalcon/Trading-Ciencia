-- Trading Science Framework - Database Initialization
--
-- Ejecutado automáticamente al crear el contenedor PostgreSQL
-- Para desarrollo: docker-compose up postgres
-- Para producción: docker-compose -f docker-compose.yml -f docker-compose.prod.yml up postgres

-- Extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- ESQUEMA PRINCIPAL
-- ============================================================

-- Tabla de señales generadas (inmutable, append-only)
CREATE TABLE IF NOT EXISTS signals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timestamp TIMESTAMPTZ NOT NULL,
    symbol VARCHAR(20) NOT NULL,
    direction VARCHAR(10) NOT NULL CHECK (direction IN ('long', 'short')),
    entry_price NUMERIC(20, 8) NOT NULL,
    stop_loss NUMERIC(20, 8) NOT NULL,
    take_profit NUMERIC(20, 8) NOT NULL,
    size NUMERIC(20, 8) NOT NULL,
    strategy_name VARCHAR(100) NOT NULL,
    strategy_version VARCHAR(20) NOT NULL,
    hypothesis_id VARCHAR(100) NOT NULL,
    indicators JSONB NOT NULL DEFAULT '{}',
    regime VARCHAR(50) NOT NULL DEFAULT 'unknown',
    confidence NUMERIC(5, 4) NOT NULL DEFAULT 0,
    order_type VARCHAR(20) NOT NULL DEFAULT 'market',
    expiry TIMESTAMPTZ,
    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_signals_timestamp ON signals(timestamp);
CREATE INDEX idx_signals_symbol ON signals(symbol);
CREATE INDEX idx_signals_hypothesis ON signals(hypothesis_id);
CREATE INDEX idx_signals_strategy ON signals(strategy_name, strategy_version);

-- Tabla de trades ejecutados (resultado de señales)
CREATE TABLE IF NOT EXISTS trades (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    signal_id UUID NOT NULL REFERENCES signals(id),
    ticket BIGINT UNIQUE,  -- Broker ticket/order ID
    open_time TIMESTAMPTZ NOT NULL,
    close_time TIMESTAMPTZ,
    open_price NUMERIC(20, 8) NOT NULL,
    close_price NUMERIC(20, 8),
    size NUMERIC(20, 8) NOT NULL,
    direction VARCHAR(10) NOT NULL CHECK (direction IN ('long', 'short')),
    profit NUMERIC(20, 8),
    commission NUMERIC(20, 8) DEFAULT 0,
    swap NUMERIC(20, 8) DEFAULT 0,
    close_reason VARCHAR(50),  -- 'sl', 'tp', 'manual', 'breaker'
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trades_signal ON trades(signal_id);
CREATE INDEX idx_trades_open_time ON trades(open_time);
CREATE INDEX idx_trades_close_time ON trades(close_time);

-- Tabla de equity curve (snapshot diario)
CREATE TABLE IF NOT EXISTS equity_snapshots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    date DATE NOT NULL UNIQUE,
    equity NUMERIC(20, 2) NOT NULL,
    balance NUMERIC(20, 2) NOT NULL,
    floating_pnl NUMERIC(20, 2) DEFAULT 0,
    open_positions INT DEFAULT 0,
    daily_pnl NUMERIC(20, 2) DEFAULT 0,
    daily_trades INT DEFAULT 0,
    max_drawdown NUMERIC(20, 2) DEFAULT 0,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_equity_date ON equity_snapshots(date);

-- Tabla de configuración de riesgo (historial de cambios)
CREATE TABLE IF NOT EXISTS risk_config_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    config JSONB NOT NULL,
    changed_by VARCHAR(100) NOT NULL,
    reason TEXT,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Tabla de eventos del sistema (auditoría)
CREATE TABLE IF NOT EXISTS system_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type VARCHAR(50) NOT NULL,
    severity VARCHAR(20) NOT NULL CHECK (severity IN ('info', 'warning', 'error', 'critical')),
    message TEXT NOT NULL,
    context JSONB DEFAULT '{}',
    source VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_type ON system_events(event_type);
CREATE INDEX idx_events_created ON system_events(created_at);

-- Tabla de hipótesis de investigación
CREATE TABLE IF NOT EXISTS hypotheses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hypothesis_id VARCHAR(100) NOT NULL UNIQUE,
    description TEXT NOT NULL,
    expected_direction VARCHAR(20) NOT NULL CHECK (expected_direction IN ('long', 'short', 'neutral')),
    source_type VARCHAR(50) NOT NULL,
    falsification_contract JSONB NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'draft',  -- draft, preregistered, tested, adjudicated
    fl_case_id VARCHAR(100),  -- Referencia a falsification-ledger
    adjudication VARCHAR(20) CHECK (adjudication IN ('support', 'against', 'uncertain')),
    adjudicated_at TIMESTAMPTZ,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_hypotheses_status ON hypotheses(status);
CREATE INDEX idx_hypotheses_fl_case ON hypotheses(fl_case_id);

-- Tabla de backtests
CREATE TABLE IF NOT EXISTS backtests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hypothesis_id UUID REFERENCES hypotheses(id),
    strategy_name VARCHAR(100) NOT NULL,
    strategy_version VARCHAR(20) NOT NULL,
    config_hash VARCHAR(32) NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    timeframe VARCHAR(10) NOT NULL,
    symbol VARCHAR(20) NOT NULL,
    n_trials INT NOT NULL,
    metrics JSONB NOT NULL,  -- DSR, PSR, PBO, MinTRL, Haircut, etc.
    cpcv_paths JSONB,  -- Paths OOS si aplica
    factor_qc_result JSONB,  -- Resultado gate factor-qc
    status VARCHAR(50) NOT NULL DEFAULT 'pending',  -- pending, passed, failed, blocked
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_backtests_hypothesis ON backtests(hypothesis_id);
CREATE INDEX idx_backtests_status ON backtests(status);

-- ============================================================
-- FUNCIONES AUXILIARES
-- ============================================================

-- Actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_hypotheses_updated_at
    BEFORE UPDATE ON hypotheses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- DATOS INICIALES
-- ============================================================

-- Configuración de riesgo por defecto
INSERT INTO risk_config_history (config, changed_by, reason)
VALUES (
    '{
        "sizing_mode": 2,
        "risk_pct_equity": 0.5,
        "max_lots": 1.0,
        "sl_mult_atr": 1.5,
        "tp_r_multiple": 2.0,
        "cooldown_minutes": 10,
        "max_trades_per_day": 5,
        "daily_loss_limit_pct": 2.0,
        "session_enable": true,
        "start_hour": 13,
        "end_hour": 20
    }'::jsonb,
    'system',
    'Initial risk configuration'
) ON CONFLICT DO NOTHING;

-- Evento de inicialización
INSERT INTO system_events (event_type, severity, message, source)
VALUES ('system_init', 'info', 'Database initialized for Trading Science Framework', 'init-db.sql')
ON CONFLICT DO NOTHING;

-- ============================================================
-- PERMISOS (usuario tsf)
-- ============================================================

-- El usuario tsf se crea vía POSTGRES_USER en docker-compose
-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO tsf;
-- GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO tsf;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO tsf;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO tsf;