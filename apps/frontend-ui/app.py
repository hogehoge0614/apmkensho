import os
import json
import time
import uuid
import logging
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "frontend-ui")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

logger = logging.getLogger(SERVICE)
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter(
    "%(asctime)s %(name)s %(levelname)s %(message)s"
))
logger.addHandler(handler)
logger.setLevel(logging.INFO)

BFF_URL = os.getenv("BFF_URL", "http://backend-for-frontend:8000")
NEW_RELIC_BROWSER_SNIPPET = os.getenv("NEW_RELIC_BROWSER_SNIPPET", "")
CW_RUM_SNIPPET = os.getenv("CW_RUM_SNIPPET", "")
NODE_TYPE = os.getenv("NODE_TYPE", "EC2")

app = FastAPI(title="frontend-ui", version="1.0.0")

static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")

http_client = httpx.AsyncClient(timeout=30.0)


def get_request_id(request: Request) -> str:
    return request.headers.get("X-Request-Id", str(uuid.uuid4()))


def structured_log(level, endpoint, request_id, status_code, latency_ms,
                   scenario=None, downstream=None, error_msg=None, extra=None):
    log_data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service_name": SERVICE,
        "environment": ENVIRONMENT,
        "endpoint": endpoint,
        "request_id": request_id,
        "status_code": status_code,
        "latency_ms": latency_ms,
        "scenario": scenario,
        "downstream_service": downstream,
        "error_message": error_msg,
    }
    if extra:
        log_data.update(extra)
    getattr(logger, level)(json.dumps(log_data))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE, "environment": ENVIRONMENT, "node_type": NODE_TYPE}


@app.get("/", response_class=HTMLResponse)
async def index():
    with open(os.path.join(static_dir, "index.html"), "r") as f:
        html = f.read()
    html = html.replace("{{NODE_TYPE}}", NODE_TYPE)
    html = html.replace("{{ENVIRONMENT}}", ENVIRONMENT)
    html = html.replace("{{NEW_RELIC_BROWSER_SNIPPET}}", NEW_RELIC_BROWSER_SNIPPET)
    html = html.replace("{{CW_RUM_SNIPPET}}", CW_RUM_SNIPPET)
    return HTMLResponse(content=html)


async def call_bff(path: str, request_id: str, headers: dict = None) -> dict:
    h = {
        "X-Request-Id": request_id,
        "X-Node-Type": NODE_TYPE,
        "X-Environment": ENVIRONMENT,
    }
    if headers:
        h.update(headers)
    try:
        resp = await http_client.get(f"{BFF_URL}{path}", headers=h)
        resp.raise_for_status()
        return resp.json()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.get("/api/checkout/{scenario}")
async def checkout(scenario: str, request: Request):
    request_id = get_request_id(request)
    start = time.time()
    valid = ["normal", "slow-inventory", "slow-payment", "payment-error",
             "external-slow", "random"]
    if scenario not in valid:
        raise HTTPException(status_code=400, detail=f"Unknown scenario: {scenario}")

    try:
        result = await call_bff(f"/api/checkout/{scenario}", request_id)
        latency = int((time.time() - start) * 1000)
        structured_log("info", f"/api/checkout/{scenario}", request_id, 200,
                       latency, scenario=scenario, downstream="backend-for-frontend")
        return JSONResponse(content=result)
    except HTTPException as e:
        latency = int((time.time() - start) * 1000)
        structured_log("error", f"/api/checkout/{scenario}", request_id,
                       e.status_code, latency, scenario=scenario,
                       downstream="backend-for-frontend", error_msg=str(e.detail))
        raise


@app.get("/api/search")
async def search(request: Request, q: str = "shoes"):
    request_id = get_request_id(request)
    start = time.time()
    result = await call_bff(f"/api/search?q={q}", request_id)
    latency = int((time.time() - start) * 1000)
    structured_log("info", "/api/search", request_id, 200, latency,
                   scenario="search", downstream="backend-for-frontend")
    return JSONResponse(content=result)


@app.get("/api/user-journey")
async def user_journey(request: Request):
    request_id = get_request_id(request)
    start = time.time()
    result = await call_bff("/api/user-journey", request_id)
    latency = int((time.time() - start) * 1000)
    structured_log("info", "/api/user-journey", request_id, 200, latency,
                   scenario="user-journey", downstream="backend-for-frontend")
    return JSONResponse(content=result)


@app.on_event("shutdown")
async def shutdown():
    await http_client.aclose()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
