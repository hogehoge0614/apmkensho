import os
import json
import time
import logging
from typing import Optional

import httpx
from fastapi import FastAPI, Request, Query, HTTPException, Form
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from pythonjsonlogger import jsonlogger

SERVICE       = os.getenv("SERVICE_NAME",  "netwatch-ui")
ENVIRONMENT   = os.getenv("ENVIRONMENT",   "demo-ec2")
NODE_TYPE     = os.getenv("NODE_TYPE",     "EC2")
DEVICE_API    = os.getenv("DEVICE_API_URL","http://device-api:8000")
ALERT_API     = os.getenv("ALERT_API_URL", "http://alert-api:8000")
CW_RUM_SNIPPET  = os.getenv("CW_RUM_SNIPPET",  "")
NR_BROWSER_SNIPPET = os.getenv("NR_BROWSER_SNIPPET", "")

logger = logging.getLogger(SERVICE)
_h = logging.StreamHandler()
_h.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(_h)
logger.setLevel(logging.INFO)

app = FastAPI(title="netwatch-ui")
templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))

_client = httpx.AsyncClient(timeout=30.0)


def _ctx(request: Request, **kwargs) -> dict:
    return {
        "request": request,
        "environment": ENVIRONMENT,
        "node_type": NODE_TYPE,
        "cw_rum_snippet": CW_RUM_SNIPPET,
        "nr_browser_snippet": NR_BROWSER_SNIPPET,
        **kwargs,
    }


def _log(event: str, endpoint: str, ms: int, status: int = 200, error: str = None, **extra):
    data = {"event": event, "endpoint": endpoint, "duration_ms": ms, "status_code": status}
    if error: data["error"] = error
    data.update(extra)
    (logger.error if error else logger.info)(json.dumps(data))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE, "environment": ENVIRONMENT}


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    start = time.time()
    try:
        dev_r   = await _client.get(f"{DEVICE_API}/devices")
        alert_r = await _client.get(f"{ALERT_API}/alerts", params={"status": "active"})
        sum_r   = await _client.get(f"{ALERT_API}/alerts/summary")
        devices = dev_r.json().get("devices", [])
        alerts  = alert_r.json().get("alerts", [])
        summary = sum_r.json()

        status_counts = {}
        area_counts   = {}
        for d in devices:
            status_counts[d["status"]] = status_counts.get(d["status"], 0) + 1
            area_counts[d["area"]]     = area_counts.get(d["area"], 0) + 1

        critical_devices = [d for d in devices if d["status"] in ("critical", "offline")]
        ms = int((time.time() - start) * 1000)
        _log("dashboard", "/", ms)
        return templates.TemplateResponse("dashboard.html", _ctx(
            request,
            total_devices=len(devices),
            status_counts=status_counts,
            area_counts=area_counts,
            critical_devices=critical_devices[:5],
            recent_alerts=alerts[:5],
            alert_summary=summary,
        ))
    except Exception as e:
        ms = int((time.time() - start) * 1000)
        _log("dashboard", "/", ms, 500, str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/devices", response_class=HTMLResponse)
async def devices_page(
    request: Request,
    area:   Optional[str] = Query(None),
    type:   Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    q:      Optional[str] = Query(None),
):
    start = time.time()
    params = {k: v for k, v in {"area": area, "type": type, "status": status, "q": q}.items() if v}
    try:
        r = await _client.get(f"{DEVICE_API}/devices", params=params)
        data = r.json()
        ms = int((time.time() - start) * 1000)
        _log("devices_list", "/devices", ms, filters=params)
        return templates.TemplateResponse("devices.html", _ctx(
            request,
            devices=data.get("devices", []),
            total=data.get("total", 0),
            query_ms=data.get("duration_ms", 0),
            filters={"area": area, "type": type, "status": status, "q": q},
        ))
    except Exception as e:
        ms = int((time.time() - start) * 1000)
        _log("devices_list", "/devices", ms, 500, str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/devices/{device_id}", response_class=HTMLResponse)
async def device_detail(device_id: str, request: Request):
    start = time.time()
    try:
        r = await _client.get(f"{DEVICE_API}/devices/{device_id}")
        if r.status_code == 404:
            raise HTTPException(status_code=404, detail="Device not found")
        device = r.json()
        ar = await _client.get(f"{ALERT_API}/alerts", params={"area": device.get("area", "")})
        all_alerts = ar.json().get("alerts", [])
        device_alerts = [a for a in all_alerts if a["device_id"] == device_id]
        ms = int((time.time() - start) * 1000)
        _log("device_detail", f"/devices/{device_id}", ms, device_id=device_id)
        return templates.TemplateResponse("device_detail.html", _ctx(
            request, device=device, device_alerts=device_alerts,
        ))
    except HTTPException:
        raise
    except Exception as e:
        ms = int((time.time() - start) * 1000)
        _log("device_detail", f"/devices/{device_id}", ms, 500, str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/alerts", response_class=HTMLResponse)
async def alerts_page(
    request: Request,
    severity: Optional[str] = Query(None),
    area:     Optional[str] = Query(None),
):
    start = time.time()
    params = {k: v for k, v in {"severity": severity, "area": area}.items() if v}
    try:
        r = await _client.get(f"{ALERT_API}/alerts", params=params)
        data = r.json()
        ms = int((time.time() - start) * 1000)
        _log("alerts_list", "/alerts", ms)
        return templates.TemplateResponse("alerts.html", _ctx(
            request,
            alerts=data.get("alerts", []),
            total=data.get("total", 0),
            filters={"severity": severity, "area": area},
        ))
    except Exception as e:
        ms = int((time.time() - start) * 1000)
        _log("alerts_list", "/alerts", ms, 500, str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/chaos", response_class=HTMLResponse)
async def chaos_page(request: Request):
    try:
        r = await _client.get(f"{DEVICE_API}/chaos/state")
        chaos_state = r.json()
    except Exception:
        chaos_state = {}
    return templates.TemplateResponse("chaos.html", _ctx(request, chaos_state=chaos_state))


# ── API proxy for chaos (called from chaos page via fetch) ──

@app.post("/api/chaos/slow-query")
async def api_slow_query(enable: bool = True, duration_ms: int = 3000):
    r = await _client.post(f"{DEVICE_API}/chaos/slow-query", params={"enable": enable, "duration_ms": duration_ms})
    return r.json()


@app.post("/api/chaos/error-inject")
async def api_error_inject(rate: int = 30):
    r = await _client.post(f"{DEVICE_API}/chaos/error-inject", params={"rate": rate})
    return r.json()


@app.post("/api/chaos/alert-storm")
async def api_alert_storm(enable: bool = True):
    r = await _client.post(f"{ALERT_API}/chaos/alert-storm", params={"enable": enable})
    return r.json()


@app.post("/api/chaos/reset")
async def api_chaos_reset():
    try:
        await _client.post(f"{DEVICE_API}/chaos/reset")
    except Exception:
        pass
    try:
        await _client.post(f"{ALERT_API}/chaos/reset")
    except Exception:
        pass
    return {"status": "reset"}


@app.post("/api/alerts/{alert_id}/resolve")
async def api_resolve_alert(alert_id: str):
    r = await _client.post(f"{ALERT_API}/alerts/{alert_id}/resolve")
    return r.json()


@app.on_event("shutdown")
async def shutdown():
    await _client.aclose()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
