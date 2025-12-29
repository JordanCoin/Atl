"""Browser automation via HTTP command server."""

import json
import re
import time
import urllib.request
import urllib.error
from dataclasses import dataclass
from typing import Optional, Dict, List, Any
from pathlib import Path


@dataclass
class ActionResult:
    """Result of a browser action."""
    success: bool
    data: Optional[Dict] = None
    error: Optional[str] = None


@dataclass
class Element:
    """Interactive element on page."""
    tag: str
    text: str
    selector: Optional[str] = None
    href: Optional[str] = None
    type: Optional[str] = None


class Browser:
    """Browser automation client."""

    def __init__(self, server_url: str = "http://localhost:9222"):
        self.server_url = server_url

    def _command(self, method: str, params: Optional[Dict] = None) -> Dict:
        """Send command to browser server."""
        payload = {
            "id": method,
            "method": method,
            "params": params or {}
        }

        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            f"{self.server_url}/command",
            data=data,
            headers={"Content-Type": "application/json"}
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode('utf-8')
                # Clean control characters that break JSON
                raw = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', raw)
                return json.loads(raw)
        except urllib.error.URLError as e:
            return {"success": False, "error": f"Connection failed: {e}"}
        except json.JSONDecodeError as e:
            return {"success": False, "error": f"Invalid JSON: {e}"}

    def _run_js(self, script: str) -> Any:
        """Run JavaScript in browser and return result."""
        result = self._command("evaluate", {"script": script})
        if "result" in result and "value" in result["result"]:
            return result["result"]["value"]
        return None

    # ========== Navigation ==========

    def goto(self, url: str, wait: bool = True, timeout: int = 10) -> ActionResult:
        """Navigate to URL."""
        result = self._command("goto", {"url": url})
        success = result.get("success", False)

        if success and wait:
            ready = self.wait_ready(timeout=timeout)
            return ActionResult(success=ready.success, data={"url": url, "ready": ready.data})

        return ActionResult(success=success, data={"url": url})

    def url(self) -> str:
        """Get current URL."""
        return self._run_js("window.location.href") or ""

    def title(self) -> str:
        """Get page title."""
        return self._run_js("document.title") or ""

    def wait_ready(self, timeout: int = 10, stability_ms: int = 500) -> ActionResult:
        """Wait for page to be ready (DOM stable, network idle)."""
        result = self._command("waitForReady", {
            "timeout": timeout,
            "stabilityMs": stability_ms
        })
        if "result" in result:
            return ActionResult(success=result["result"].get("ready", False), data=result["result"])
        return ActionResult(success=False, error="Wait failed")

    # ========== Actions ==========

    def click(self, selector: str) -> ActionResult:
        """Click element by CSS selector."""
        result = self._command("click", {"selector": selector})
        success = result.get("success", False)
        if not success:
            return ActionResult(success=False, error=f"Click failed: {selector}")
        return ActionResult(success=True, data={"selector": selector})

    def click_text(self, text: str) -> ActionResult:
        """Click element by visible text."""
        # Escape single quotes in text
        escaped = text.replace("'", "\\'")
        script = f"""(function(){{
            const t = '{escaped}'.toLowerCase();
            const els = [...document.querySelectorAll('button,a,input[type=submit],input[type=button],[role=button]')]
                .filter(e =>
                    (e.textContent||'').toLowerCase().includes(t) ||
                    (e.value||'').toLowerCase().includes(t) ||
                    (e.title||'').toLowerCase().includes(t) ||
                    (e.getAttribute('aria-label')||'').toLowerCase().includes(t)
                );
            if (els[0]) {{
                els[0].scrollIntoView({{block:'center'}});
                els[0].click();
                return {{success: true, tag: els[0].tagName, text: els[0].textContent?.substring(0,50)}};
            }}
            return {{success: false, error: 'not found'}};
        }})()"""
        result = self._run_js(script)
        if result and result.get("success"):
            return ActionResult(success=True, data=result)
        return ActionResult(success=False, error=f"Text not found: {text}")

    def fill(self, selector: str, value: str) -> ActionResult:
        """Fill input field."""
        result = self._command("fill", {"selector": selector, "value": value})
        success = result.get("success", False)
        return ActionResult(success=success, data={"selector": selector, "value": value})

    def press(self, key: str) -> ActionResult:
        """Press keyboard key."""
        result = self._command("press", {"key": key})
        return ActionResult(success=result.get("success", False), data={"key": key})

    def type_text(self, text: str, selector: Optional[str] = None) -> ActionResult:
        """Type text, optionally into specific element."""
        if selector:
            self._run_js(f"document.querySelector('{selector}')?.focus()")
        result = self._command("type", {"text": text})
        return ActionResult(success=result.get("success", False), data={"text": text})

    def scroll(self, direction: str = "down", amount: int = 300) -> ActionResult:
        """Scroll page."""
        delta = amount if direction == "down" else -amount
        self._run_js(f"window.scrollBy(0, {delta})")
        return ActionResult(success=True, data={"direction": direction, "amount": amount})

    def scroll_to(self, selector: str) -> ActionResult:
        """Scroll element into view."""
        self._run_js(f"document.querySelector('{selector}')?.scrollIntoView({{block:'center'}})")
        return ActionResult(success=True, data={"selector": selector})

    # ========== Page Analysis ==========

    def get_text(self, selector: str) -> Optional[str]:
        """Get text content of element."""
        return self._run_js(f"document.querySelector('{selector}')?.textContent?.trim()")

    def has_text(self, text: str) -> bool:
        """Check if text exists on page."""
        escaped = text.replace("'", "\\'")
        result = self._run_js(f"document.body.textContent.toLowerCase().includes('{escaped}'.toLowerCase())")
        return result == True

    def count(self, selector: str) -> int:
        """Count elements matching selector."""
        result = self._run_js(f"document.querySelectorAll('{selector}').length")
        return result or 0

    def get_interactives(self, limit: int = 30) -> List[Element]:
        """Get list of interactive elements."""
        script = f"""(function(){{
            const els = [];
            document.querySelectorAll('button,a[href],input,select,textarea,[role=button],[onclick]').forEach((e, i) => {{
                if (i >= {limit}) return;
                const r = e.getBoundingClientRect();
                if (r.width === 0 || r.height === 0) return;
                const text = e.textContent?.trim() || e.value || e.title || e.getAttribute('aria-label') || e.placeholder || '';
                if (!text && e.tagName !== 'INPUT') return;
                els.push({{
                    tag: e.tagName,
                    text: text.substring(0, 60),
                    type: e.type || null,
                    id: e.id || null,
                    href: e.href || null
                }});
            }});
            return els;
        }})()"""
        result = self._run_js(script)
        if not result:
            return []
        return [Element(
            tag=e.get("tag", ""),
            text=e.get("text", ""),
            type=e.get("type"),
            href=e.get("href"),
            selector=f"#{e['id']}" if e.get("id") else None
        ) for e in result]

    # ========== Capture ==========

    def capture_light(self) -> Dict:
        """Capture page text and interactives (smallest, ~9KB)."""
        result = self._command("captureLight", {})
        if "result" in result:
            return result["result"]
        return {"error": "Capture failed"}

    def capture_jpeg(self, quality: int = 80, full_page: bool = False) -> Dict:
        """Capture JPEG screenshot."""
        result = self._command("captureJPEG", {"quality": quality, "fullPage": full_page})
        if "result" in result:
            return {
                "url": result["result"].get("url"),
                "title": result["result"].get("title"),
                "size": result["result"].get("size"),
                "width": result["result"].get("width"),
                "height": result["result"].get("height")
            }
        return {"error": "Capture failed"}

    def capture_pdf(self, save_path: str, name: str) -> Optional[str]:
        """Capture full page PDF. Returns path to saved file."""
        result = self._command("captureForVision", {"savePath": save_path, "name": name})
        if "result" in result:
            return result["result"].get("savedTo")
        return None

    # ========== Utility ==========

    def wait(self, seconds: float):
        """Wait for specified seconds."""
        time.sleep(seconds)

    def is_connected(self) -> bool:
        """Check if browser server is responding."""
        try:
            result = self._command("evaluate", {"script": "true"})
            return result.get("result", {}).get("value") == True
        except:
            return False


# Convenience singleton
_browser: Optional[Browser] = None

def get_browser(server_url: str = "http://localhost:9222") -> Browser:
    """Get or create browser instance."""
    global _browser
    if _browser is None:
        _browser = Browser(server_url)
    return _browser
