"""Run and metrics tracking."""

from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, List, Any

from .db import transaction, DEFAULT_DB_PATH

RUNS_DIR = DEFAULT_DB_PATH.parent.parent / "runs"


def start(run_id: str, workflow: str, simulator_udid: Optional[str] = None) -> Dict:
    """Start a new run."""
    now = datetime.utcnow().isoformat() + "Z"
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    with transaction() as conn:
        conn.execute("""
            INSERT INTO runs (id, workflow, simulator_udid, status, start_time, run_dir)
            VALUES (?, ?, ?, 'running', ?, ?)
        """, (run_id, workflow, simulator_udid, now, str(run_dir)))

        # Initialize metrics
        conn.execute("INSERT INTO metrics (run_id) VALUES (?)", (run_id,))

        # Mark simulator as busy if specified
        if simulator_udid:
            conn.execute("""
                UPDATE simulators SET state = 'busy', current_task = ?
                WHERE udid = ?
            """, (run_id, simulator_udid))

    return {"run_id": run_id, "run_dir": str(run_dir), "status": "running"}


def complete(run_id: str, status: str = "completed", total_steps: int = 0) -> Dict:
    """Complete a run."""
    now = datetime.utcnow().isoformat() + "Z"

    with transaction() as conn:
        # Get simulator to release
        row = conn.execute("SELECT simulator_udid FROM runs WHERE id = ?", (run_id,)).fetchone()
        sim_udid = row["simulator_udid"] if row else None

        # Update run
        conn.execute("""
            UPDATE runs SET status = ?, end_time = ?, total_steps = ?
            WHERE id = ?
        """, (status, now, total_steps, run_id))

        # Release simulator
        if sim_udid:
            conn.execute("""
                UPDATE simulators SET state = 'available', current_task = NULL
                WHERE udid = ?
            """, (sim_udid,))

    return {"run_id": run_id, "status": status}


def progress(run_id: str, current_step: int, total_steps: Optional[int] = None) -> Dict:
    """Update run progress."""
    with transaction() as conn:
        if total_steps:
            conn.execute("""
                UPDATE runs SET current_step = ?, total_steps = ?
                WHERE id = ?
            """, (current_step, total_steps, run_id))
        else:
            conn.execute("UPDATE runs SET current_step = ? WHERE id = ?", (current_step, run_id))

    return {"run_id": run_id, "current_step": current_step}


def get(run_id: str) -> Optional[Dict]:
    """Get run details."""
    with transaction() as conn:
        row = conn.execute("""
            SELECT r.*, m.*
            FROM runs r
            LEFT JOIN metrics m ON r.id = m.run_id
            WHERE r.id = ?
        """, (run_id,)).fetchone()

        if row:
            return dict(row)
    return None


def list_runs(status: Optional[str] = None, limit: int = 20) -> List[Dict]:
    """List runs, optionally filtered by status."""
    with transaction() as conn:
        if status:
            rows = conn.execute("""
                SELECT id, workflow, status, start_time, end_time
                FROM runs
                WHERE status = ?
                ORDER BY start_time DESC
                LIMIT ?
            """, (status, limit)).fetchall()
        else:
            rows = conn.execute("""
                SELECT id, workflow, status, start_time, end_time
                FROM runs
                ORDER BY start_time DESC
                LIMIT ?
            """, (limit,)).fetchall()

        return [dict(row) for row in rows]


def update_metrics(run_id: str, **kwargs) -> Dict:
    """Update metrics for a run. Pass field=value pairs."""
    if not kwargs:
        return {"updated": False}

    # Build SET clause
    set_parts = []
    values = []
    for key, value in kwargs.items():
        if key.startswith('+'):
            # Increment mode: +field=value
            field = key[1:]
            set_parts.append(f"{field} = {field} + ?")
        else:
            set_parts.append(f"{key} = ?")
        values.append(value)

    values.append(run_id)

    with transaction() as conn:
        conn.execute(f"""
            UPDATE metrics SET {', '.join(set_parts)}
            WHERE run_id = ?
        """, values)

    return {"updated": True, "run_id": run_id}


def add_capture(run_id: str, mode: str, byte_count: int) -> Dict:
    """Record a capture."""
    field_captures = f"captures_{mode}"
    field_bytes = f"bytes_{mode}"

    with transaction() as conn:
        conn.execute(f"""
            UPDATE metrics
            SET {field_captures} = {field_captures} + 1,
                {field_bytes} = {field_bytes} + ?,
                bytes_total = bytes_total + ?,
                tokens_estimated = CAST((bytes_total + ?) * 0.25 AS INTEGER),
                cost_usd = (bytes_total + ?) * 0.25 * 3 / 1000000
            WHERE run_id = ?
        """, (byte_count, byte_count, byte_count, byte_count, run_id))

    return {"recorded": True}


def add_action(run_id: str, action_type: str) -> Dict:
    """Record an action (click, type, navigation, scroll)."""
    field = f"actions_{action_type}s"  # clicks, types, navigations, scrolls

    with transaction() as conn:
        conn.execute(f"""
            UPDATE metrics SET {field} = {field} + 1
            WHERE run_id = ?
        """, (run_id,))

    return {"recorded": True}


def get_metrics(run_id: str) -> Optional[Dict]:
    """Get metrics for a run."""
    with transaction() as conn:
        row = conn.execute("SELECT * FROM metrics WHERE run_id = ?", (run_id,)).fetchone()
        if row:
            return dict(row)
    return None


def aggregate() -> Dict:
    """Aggregate metrics across all completed runs."""
    with transaction() as conn:
        row = conn.execute("""
            SELECT
                COUNT(*) as total_runs,
                SUM(bytes_total) as total_bytes,
                SUM(tokens_estimated) as total_tokens,
                SUM(cost_usd) as total_cost,
                SUM(captures_light + captures_jpeg + captures_pdf) as total_captures,
                SUM(actions_clicks + actions_types + actions_navigations + actions_scrolls) as total_actions
            FROM metrics m
            JOIN runs r ON m.run_id = r.id
            WHERE r.status = 'completed'
        """).fetchone()

        return {
            "total_runs": row["total_runs"] or 0,
            "total_bytes": row["total_bytes"] or 0,
            "total_tokens": row["total_tokens"] or 0,
            "total_cost_usd": round(row["total_cost"] or 0, 4),
            "total_captures": row["total_captures"] or 0,
            "total_actions": row["total_actions"] or 0
        }


def export_run(run_id: str) -> Optional[Dict]:
    """Export full run data including metrics."""
    run = get(run_id)
    if not run:
        return None

    # Try to load manifest and report from disk
    run_dir = Path(run.get("run_dir", ""))
    if run_dir.exists():
        import json
        manifest_path = run_dir / "manifest.json"
        if manifest_path.exists():
            run["manifest"] = json.loads(manifest_path.read_text())

    return run
