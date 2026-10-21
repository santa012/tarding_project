CREATE TABLE IF NOT EXISTS trades (
    id            BIGSERIAL PRIMARY KEY,
    source_ea     TEXT NOT NULL,          -- e.g. 'GoldPreciseM15'
    event_time    TIMESTAMPTZ NOT NULL,
    event         TEXT NOT NULL,          -- OPEN, CLOSE, OPEN_FAILED
    ticket        BIGINT NOT NULL,
    type          TEXT NOT NULL,          -- BUY, SELL, CLOSE_BUY, CLOSE_SELL
    volume        DOUBLE PRECISION NOT NULL,
    price         DOUBLE PRECISION NOT NULL,
    sl            DOUBLE PRECISION NOT NULL DEFAULT 0,
    tp            DOUBLE PRECISION NOT NULL DEFAULT 0,
    profit        DOUBLE PRECISION NOT NULL DEFAULT 0,
    comment       TEXT NOT NULL DEFAULT '',
    account_login BIGINT,                  -- MT5 account number the EA ran on (NULL for older logs without this column)
    imported_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_ea, ticket, event)
);

CREATE INDEX IF NOT EXISTS idx_trades_event_time ON trades (event_time);
CREATE INDEX IF NOT EXISTS idx_trades_source_ea ON trades (source_ea);
CREATE INDEX IF NOT EXISTS idx_trades_event ON trades (event);
CREATE INDEX IF NOT EXISTS idx_trades_account_login ON trades (account_login);

-- Tracks how far each source log file has been read, so the watcher
-- can resume without re-reading the whole file every cycle.
CREATE TABLE IF NOT EXISTS import_cursors (
    file_name     TEXT PRIMARY KEY,
    bytes_read    BIGINT NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Small key/value store, e.g. 'starting_capital' for the dashboard's P/L% cards.
CREATE TABLE IF NOT EXISTS settings (
    key           TEXT PRIMARY KEY,
    value         TEXT NOT NULL
);
