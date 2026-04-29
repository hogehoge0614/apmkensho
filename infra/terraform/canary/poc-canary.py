# CloudWatch Synthetics Canary Script
# Monitors the PoC application health endpoint
import urllib.request
import os

async def handler(event, context):
    target_url = os.environ.get("TARGET_URL", "https://example.com")
    url = target_url.rstrip("/") + "/health"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as response:
            status = response.status
            body = response.read().decode("utf-8")
        if status == 200:
            return {"statusCode": 200, "body": f"Health check passed: {status}"}
        else:
            raise Exception(f"Health check failed with status: {status}")
    except Exception as e:
        raise Exception(f"Canary failed: {str(e)}")
