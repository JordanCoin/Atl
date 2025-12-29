"""SQLite database connection and schema management."""

import sqlite3
from pathlib import Path
from typing import Optional
from contextlib import contextmanager

# Default database location
DEFAULT_DB_PATH = Path(__file__).parent.parent / "state" / "atl.db"


def get_connection(db_path: Optional[Path] = None) -> sqlite3.Connection:
    """Get a database connection with row factory."""
    path = db_path or DEFAULT_DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row  # Access columns by name
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


@contextmanager
def transaction(db_path: Optional[Path] = None):
    """Context manager for database transactions."""
    conn = get_connection(db_path)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db(db_path: Optional[Path] = None) -> None:
    """Initialize database schema."""
    with transaction(db_path) as conn:
        # Selectors table - learned CSS selectors per domain
        conn.execute("""
            CREATE TABLE IF NOT EXISTS selectors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                domain TEXT NOT NULL,
                action TEXT NOT NULL,
                selector TEXT NOT NULL,
                success_count INTEGER DEFAULT 0,
                fail_count INTEGER DEFAULT 0,
                attributes TEXT,  -- JSON for extra attributes
                last_used TEXT,
                last_failed TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(domain, action)
            )
        """)

        # Simulators table - available simulators and their state
        conn.execute("""
            CREATE TABLE IF NOT EXISTS simulators (
                udid TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                device_type TEXT,  -- iPhone, iPad
                screen_size TEXT,  -- 393x852
                pool TEXT,         -- iPhone-393x852
                state TEXT DEFAULT 'offline',  -- offline, available, busy
                current_task TEXT,
                port INTEGER,
                last_activity TEXT
            )
        """)

        # Runs table - workflow execution tracking
        conn.execute("""
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                workflow TEXT NOT NULL,
                simulator_udid TEXT,
                status TEXT DEFAULT 'running',  -- running, completed, failed
                start_time TEXT DEFAULT CURRENT_TIMESTAMP,
                end_time TEXT,
                total_steps INTEGER DEFAULT 0,
                current_step INTEGER DEFAULT 0,
                run_dir TEXT,
                FOREIGN KEY (simulator_udid) REFERENCES simulators(udid)
            )
        """)

        # Metrics table - per-run metrics
        conn.execute("""
            CREATE TABLE IF NOT EXISTS metrics (
                run_id TEXT PRIMARY KEY,
                captures_light INTEGER DEFAULT 0,
                captures_jpeg INTEGER DEFAULT 0,
                captures_pdf INTEGER DEFAULT 0,
                bytes_light INTEGER DEFAULT 0,
                bytes_jpeg INTEGER DEFAULT 0,
                bytes_pdf INTEGER DEFAULT 0,
                bytes_total INTEGER DEFAULT 0,
                tokens_estimated INTEGER DEFAULT 0,
                cost_usd REAL DEFAULT 0,
                actions_clicks INTEGER DEFAULT 0,
                actions_types INTEGER DEFAULT 0,
                actions_navigations INTEGER DEFAULT 0,
                actions_scrolls INTEGER DEFAULT 0,
                selector_hits INTEGER DEFAULT 0,
                selector_misses INTEGER DEFAULT 0,
                errors INTEGER DEFAULT 0,
                FOREIGN KEY (run_id) REFERENCES runs(id)
            )
        """)

        # Create indexes for common queries
        conn.execute("CREATE INDEX IF NOT EXISTS idx_selectors_domain ON selectors(domain)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_simulators_state ON simulators(state)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_simulators_pool ON simulators(pool)")


def reset_db(db_path: Optional[Path] = None) -> None:
    """Drop all tables and reinitialize."""
    with transaction(db_path) as conn:
        conn.execute("DROP TABLE IF EXISTS metrics")
        conn.execute("DROP TABLE IF EXISTS runs")
        conn.execute("DROP TABLE IF EXISTS simulators")
        conn.execute("DROP TABLE IF EXISTS selectors")
    init_db(db_path)
