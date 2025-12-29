"""Simulator pool management."""

import subprocess
import json
from datetime import datetime
from typing import Optional, Dict, List

from .db import transaction


def _run_simctl(*args) -> str:
    """Run xcrun simctl command."""
    result = subprocess.run(
        ["xcrun", "simctl"] + list(args),
        capture_output=True,
        text=True
    )
    return result.stdout


def _get_screen_size(name: str) -> str:
    """Determine screen size from device name."""
    if "iPad" in name:
        if "Pro 13" in name or "Air 13" in name:
            return "1032x1376"
        elif "Pro 11" in name or "Air 11" in name:
            return "834x1194"
        else:
            return "820x1180"
    elif "Pro Max" in name:
        return "430x932"
    elif "Pro" in name:
        return "393x852"
    elif "Air" in name:
        return "320x693"
    else:
        return "393x852"  # Default iPhone


def _get_device_type(name: str) -> str:
    """Determine device type from name."""
    return "iPad" if "iPad" in name else "iPhone"


def refresh() -> Dict:
    """Refresh simulator list from simctl."""
    output = _run_simctl("list", "devices", "available", "--json")
    data = json.loads(output)
    now = datetime.utcnow().isoformat() + "Z"

    count = 0
    pools = {}

    with transaction() as conn:
        for runtime, devices in data.get("devices", {}).items():
            for device in devices:
                udid = device["udid"]
                name = device["name"]
                sim_state = device["state"]

                device_type = _get_device_type(name)
                screen_size = _get_screen_size(name)
                pool = f"{device_type}-{screen_size}"

                # Map simctl state to our state
                if sim_state == "Booted":
                    state = "available"
                else:
                    state = "offline"

                # Check if busy (has active task)
                row = conn.execute("""
                    SELECT current_task FROM simulators WHERE udid = ?
                """, (udid,)).fetchone()
                if row and row["current_task"]:
                    state = "busy"

                # Upsert simulator
                conn.execute("""
                    INSERT INTO simulators (udid, name, device_type, screen_size, pool, state, last_activity)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(udid) DO UPDATE SET
                        name = excluded.name,
                        device_type = excluded.device_type,
                        screen_size = excluded.screen_size,
                        pool = excluded.pool,
                        state = CASE WHEN simulators.current_task IS NOT NULL THEN 'busy' ELSE excluded.state END,
                        last_activity = excluded.last_activity
                """, (udid, name, device_type, screen_size, pool, state, now))

                # Track pools
                if pool not in pools:
                    pools[pool] = 0
                pools[pool] += 1
                count += 1

    return {"simulators": count, "pools": pools}


def list_sims(state: Optional[str] = None) -> List[Dict]:
    """List simulators, optionally filtered by state."""
    with transaction() as conn:
        if state:
            rows = conn.execute("""
                SELECT udid, name, pool, state, current_task
                FROM simulators
                WHERE state = ?
                ORDER BY name
            """, (state,)).fetchall()
        else:
            rows = conn.execute("""
                SELECT udid, name, pool, state, current_task
                FROM simulators
                ORDER BY name
            """).fetchall()

        return [dict(row) for row in rows]


def pools() -> Dict[str, List[str]]:
    """Get simulator pools (grouped by screen size)."""
    with transaction() as conn:
        rows = conn.execute("""
            SELECT pool, udid, name, state
            FROM simulators
            ORDER BY pool, name
        """).fetchall()

        result = {}
        for row in rows:
            pool = row["pool"]
            if pool not in result:
                result[pool] = []
            result[pool].append({
                "udid": row["udid"],
                "name": row["name"],
                "state": row["state"]
            })

        return result


def acquire(pool: str, task_id: str) -> Optional[str]:
    """Acquire an available simulator from a pool."""
    now = datetime.utcnow().isoformat() + "Z"

    with transaction() as conn:
        # Find first available in pool
        row = conn.execute("""
            SELECT udid FROM simulators
            WHERE pool = ? AND state = 'available'
            LIMIT 1
        """, (pool,)).fetchone()

        if not row:
            return None

        udid = row["udid"]

        # Mark as busy
        conn.execute("""
            UPDATE simulators
            SET state = 'busy', current_task = ?, last_activity = ?
            WHERE udid = ?
        """, (task_id, now, udid))

        return udid


def release(udid: str) -> Dict:
    """Release a simulator back to the pool."""
    now = datetime.utcnow().isoformat() + "Z"

    # Check if still booted
    output = _run_simctl("list", "devices", "--json")
    data = json.loads(output)

    new_state = "offline"
    for devices in data.get("devices", {}).values():
        for device in devices:
            if device["udid"] == udid and device["state"] == "Booted":
                new_state = "available"
                break

    with transaction() as conn:
        conn.execute("""
            UPDATE simulators
            SET state = ?, current_task = NULL, last_activity = ?
            WHERE udid = ?
        """, (new_state, now, udid))

    return {"udid": udid, "state": new_state}


def get(udid: str) -> Optional[Dict]:
    """Get simulator details."""
    with transaction() as conn:
        row = conn.execute("SELECT * FROM simulators WHERE udid = ?", (udid,)).fetchone()
        if row:
            return dict(row)
    return None


def stats() -> Dict:
    """Get simulator statistics."""
    with transaction() as conn:
        row = conn.execute("""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN state = 'available' THEN 1 ELSE 0 END) as available,
                SUM(CASE WHEN state = 'busy' THEN 1 ELSE 0 END) as busy,
                SUM(CASE WHEN state = 'offline' THEN 1 ELSE 0 END) as offline,
                COUNT(DISTINCT pool) as pools
            FROM simulators
        """).fetchone()

        return {
            "total": row["total"],
            "available": row["available"],
            "busy": row["busy"],
            "offline": row["offline"],
            "pools": row["pools"]
        }
