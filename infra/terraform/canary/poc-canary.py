# CloudWatch Synthetics Canary — NetWatch multi-endpoint check
# Tests: / /devices /devices/TKY-CORE-001 /alerts
import urllib.request
import urllib.error
import os
import json
import time


def _get(url: str, expected_text: str | None = None, timeout: int = 15):
    """HTTP GET and optionally assert response body contains expected_text."""
    start = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": "CloudWatch-Canary/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        status = resp.status
        body = resp.read().decode("utf-8", errors="replace")
    elapsed_ms = int((time.time() - start) * 1000)
    if status != 200:
        raise Exception(f"Expected HTTP 200, got {status} for {url}")
    if expected_text and expected_text not in body:
        raise Exception(f"Expected '{expected_text}' in response body for {url}")
    return {"url": url, "status": status, "elapsed_ms": elapsed_ms, "size": len(body)}


async def handler(event, context):
    base = os.environ.get("TARGET_URL", "https://example.com").rstrip("/")

    checks = [
        # (path, keyword_in_body)
        ("/",                      "NetWatch"),
        ("/devices",               "devices"),
        ("/devices/TKY-CORE-001",  "TKY-CORE-001"),
        ("/alerts",                "alerts"),
    ]

    results = []
    failures = []

    for path, keyword in checks:
        url = base + path
        try:
            r = _get(url, expected_text=keyword)
            results.append({**r, "ok": True})
            print(f"[OK]   {path} → HTTP {r['status']} {r['elapsed_ms']}ms ({r['size']}bytes)")
        except Exception as exc:
            failures.append({"url": url, "error": str(exc)})
            results.append({"url": url, "ok": False, "error": str(exc)})
            print(f"[FAIL] {path} → {exc}")

    summary = {
        "total": len(checks),
        "passed": len(results) - len(failures),
        "failed": len(failures),
        "results": results,
    }

    if failures:
        raise Exception(f"Canary FAILED ({len(failures)}/{len(checks)}): " + json.dumps(failures))

    return {"statusCode": 200, "body": json.dumps(summary)}
