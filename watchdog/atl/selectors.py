"""Selector cache operations."""

import json
from datetime import datetime
from typing import Optional, Dict, List, Any
from urllib.parse import urlparse

from .db import transaction


def _extract_domain(url: str) -> str:
    """Extract domain from URL."""
    if not url.startswith(('http://', 'https://')):
        return url  # Already a domain
    parsed = urlparse(url)
    # Remove www. prefix
    domain = parsed.netloc
    if domain.startswith('www.'):
        domain = domain[4:]
    return domain


def learn(action: str, selector: str, url: str, attributes: Optional[Dict] = None) -> Dict:
    """Learn a successful selector for an action on a domain."""
    domain = _extract_domain(url)
    now = datetime.utcnow().isoformat() + "Z"
    attrs_json = json.dumps(attributes) if attributes else None

    with transaction() as conn:
        # Try to update existing
        cursor = conn.execute("""
            UPDATE selectors
            SET selector = ?, success_count = success_count + 1,
                last_used = ?, attributes = COALESCE(?, attributes)
            WHERE domain = ? AND action = ?
        """, (selector, now, attrs_json, domain, action))

        if cursor.rowcount == 0:
            # Insert new
            conn.execute("""
                INSERT INTO selectors (domain, action, selector, success_count, last_used, attributes)
                VALUES (?, ?, ?, 1, ?, ?)
            """, (domain, action, selector, now, attrs_json))

    return {"success": True, "domain": domain, "action": action, "selector": selector}


def recall(action: str, url: str) -> Optional[Dict]:
    """Get cached selector for an action on a domain."""
    domain = _extract_domain(url)

    with transaction() as conn:
        row = conn.execute("""
            SELECT selector, success_count, fail_count, attributes
            FROM selectors
            WHERE domain = ? AND action = ?
        """, (domain, action)).fetchone()

        if row:
            return {
                "selector": row["selector"],
                "success_count": row["success_count"],
                "fail_count": row["fail_count"],
                "reliability": row["success_count"] / max(1, row["success_count"] + row["fail_count"]),
                "attributes": json.loads(row["attributes"]) if row["attributes"] else {}
            }
    return None


def fail(action: str, selector: str, url: str) -> Dict:
    """Record a selector failure."""
    domain = _extract_domain(url)
    now = datetime.utcnow().isoformat() + "Z"

    with transaction() as conn:
        conn.execute("""
            UPDATE selectors
            SET fail_count = fail_count + 1, last_failed = ?
            WHERE domain = ? AND action = ? AND selector = ?
        """, (now, domain, action, selector))

    return {"recorded": True, "domain": domain, "action": action}


def get_all(url: str) -> Dict[str, Any]:
    """Get all selectors for a domain."""
    domain = _extract_domain(url)

    with transaction() as conn:
        rows = conn.execute("""
            SELECT action, selector, success_count, fail_count, last_used
            FROM selectors
            WHERE domain = ?
            ORDER BY success_count DESC
        """, (domain,)).fetchall()

        return {
            "domain": domain,
            "selectors": {
                row["action"]: {
                    "selector": row["selector"],
                    "success_count": row["success_count"],
                    "fail_count": row["fail_count"],
                    "last_used": row["last_used"]
                }
                for row in rows
            }
        }


def get_domains() -> List[str]:
    """Get all domains with cached selectors."""
    with transaction() as conn:
        rows = conn.execute("SELECT DISTINCT domain FROM selectors ORDER BY domain").fetchall()
        return [row["domain"] for row in rows]


def stats() -> Dict:
    """Get selector cache statistics."""
    with transaction() as conn:
        row = conn.execute("""
            SELECT
                COUNT(*) as total,
                COUNT(DISTINCT domain) as domains,
                SUM(success_count) as total_successes,
                SUM(fail_count) as total_failures
            FROM selectors
        """).fetchone()

        return {
            "total_selectors": row["total"],
            "domains": row["domains"],
            "total_successes": row["total_successes"] or 0,
            "total_failures": row["total_failures"] or 0,
            "overall_reliability": (row["total_successes"] or 0) / max(1, (row["total_successes"] or 0) + (row["total_failures"] or 0))
        }


def clear(domain: Optional[str] = None) -> Dict:
    """Clear selector cache for a domain or all domains."""
    with transaction() as conn:
        if domain:
            cursor = conn.execute("DELETE FROM selectors WHERE domain = ?", (domain,))
        else:
            cursor = conn.execute("DELETE FROM selectors")

        return {"deleted": cursor.rowcount}


def export_all() -> Dict[str, Any]:
    """Export all selectors as nested dict (for compatibility)."""
    with transaction() as conn:
        rows = conn.execute("""
            SELECT domain, action, selector, success_count, fail_count,
                   last_used, last_failed, attributes, created_at
            FROM selectors
            ORDER BY domain, action
        """).fetchall()

        result = {}
        for row in rows:
            domain = row["domain"]
            if domain not in result:
                result[domain] = {"domain": domain, "selectors": {}}

            result[domain]["selectors"][row["action"]] = {
                "selector": row["selector"],
                "successCount": row["success_count"],
                "failCount": row["fail_count"],
                "lastUsed": row["last_used"],
                "lastFailed": row["last_failed"],
                "attributes": json.loads(row["attributes"]) if row["attributes"] else {},
                "discoveredAt": row["created_at"]
            }

        return result
