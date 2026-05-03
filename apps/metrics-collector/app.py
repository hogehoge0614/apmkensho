import os
import json
import random
import logging

from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "metrics-collector")
ENVIRONMENT = os.getenv("ENVIRONMENT", "eks-ec2-appsignals")

logger = logging.getLogger(SERVICE)
_h = logging.StreamHandler()
_h.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(_h)
logger.setLevel(logging.INFO)

app = FastAPI(title="metrics-collector", version="1.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# Metric value ranges by device status
_RANGES = {
    "active":      dict(cpu=(15, 65),   mem=(35, 70),   bw_in=(50, 800),    bw_out=(30, 600),   loss=(0, 0.5),   lat=(0.5, 5)),
    "warning":     dict(cpu=(70, 88),   mem=(75, 88),   bw_in=(850, 980),   bw_out=(700, 900),  loss=(5, 15),    lat=(80, 400)),
    "critical":    dict(cpu=(92, 99),   mem=(90, 99),   bw_in=(990, 1000),  bw_out=(980, 1000), loss=(20, 60),   lat=(800, 5000)),
    "offline":     dict(cpu=(0, 0),     mem=(0, 0),     bw_in=(0, 0),       bw_out=(0, 0),      loss=(0, 0),     lat=(0, 0)),
    "maintenance": dict(cpu=(0, 5),     mem=(5, 15),    bw_in=(0, 10),      bw_out=(0, 10),     loss=(0, 0),     lat=(0, 0)),
}


def _pick(lo: float, hi: float, decimals: int = 1) -> float:
    if lo == hi:
        return lo
    return round(random.uniform(lo, hi), decimals)


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/metrics/{device_id}")
async def get_metrics(device_id: str, status: str = Query("active")):
    r = _RANGES.get(status, _RANGES["active"])
    metrics = {
        "cpu_usage":     _pick(*r["cpu"]),
        "memory_usage":  _pick(*r["mem"]),
        "bandwidth_in":  _pick(*r["bw_in"]),
        "bandwidth_out": _pick(*r["bw_out"]),
        "packet_loss":   _pick(*r["loss"], decimals=2),
        "latency_ms":    _pick(*r["lat"]),
    }
    logger.info(json.dumps({
        "event": "get_metrics",
        "device_id": device_id,
        "status": status,
        "service": SERVICE,
        "environment": ENVIRONMENT,
    }))
    return {"device_id": device_id, "status": status, "metrics": metrics}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
