"""Original calendar API plus a same-origin local web UI.

Start:

    uvicorn web_app:app --host 127.0.0.1 --port 8787

Use --host 0.0.0.0 only if you want other devices on the same LAN
to open the page. Do not put this on the public internet without a
reverse proxy and extra auth. The MCP HTTP transport still does not
check CALENDAR_TOKEN.
"""
from __future__ import annotations

import json
import re
import uuid
from pathlib import Path

from fastapi import Depends, File, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

import config
from app import app

WEB_DIR = Path(__file__).resolve().parents[1] / "web"
DATA_DIR = Path(config.CALENDAR_DB).expanduser().resolve().parent
PLACED_DIR = DATA_DIR / "placed"
PHOTO_DIR = DATA_DIR / "photos"
_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
_PHOTO_RE = re.compile(r"^[0-9a-f]{32}\.jpg$")


async def _require_token(x_calendar_token: str = Header("", alias="X-Calendar-Token")) -> None:
    expected = config.CALENDAR_TOKEN
    if not expected or not x_calendar_token or x_calendar_token != expected:
        raise HTTPException(status_code=401, detail="invalid calendar token")


def _date_or_400(date: str) -> str:
    if not _DATE_RE.fullmatch(date):
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")
    return date


@app.get("/api/v1/calendar/placed/{date}", dependencies=[Depends(_require_token)])
async def placed_get(date: str) -> dict:
    date = _date_or_400(date)
    path = PLACED_DIR / f"{date}.json"
    if not path.is_file():
        return {"date": date, "items": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail=f"placed read failed: {exc}") from exc
    items = data.get("items") if isinstance(data, dict) else data
    if not isinstance(items, list):
        items = []
    return {"date": date, "items": items}


@app.put("/api/v1/calendar/placed/{date}", dependencies=[Depends(_require_token)])
async def placed_put(date: str, payload: dict) -> dict:
    date = _date_or_400(date)
    items = payload.get("items")
    if not isinstance(items, list):
        raise HTTPException(status_code=400, detail="items must be a list")
    PLACED_DIR.mkdir(parents=True, exist_ok=True)
    path = PLACED_DIR / f"{date}.json"
    tmp = PLACED_DIR / f".{date}.{uuid.uuid4().hex}.tmp"
    body = json.dumps({"date": date, "items": items}, ensure_ascii=False, indent=2)
    try:
        tmp.write_text(body, encoding="utf-8")
        tmp.replace(path)
    except OSError:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail="failed to store placed items")
    return {"ok": True, "date": date, "count": len(items)}


@app.post("/api/v1/calendar/photos", dependencies=[Depends(_require_token)])
async def photo_upload(file: UploadFile = File(...)) -> dict:
    data = await file.read()
    if len(data) > 4 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="photo too large")
    if not data:
        raise HTTPException(status_code=400, detail="empty photo")
    PHOTO_DIR.mkdir(parents=True, exist_ok=True)
    name = f"{uuid.uuid4().hex}.jpg"
    path = PHOTO_DIR / name
    path.write_bytes(data)
    return {"ok": True, "file": name, "url": f"/media/photos/{name}"}


@app.get("/media/photos/{name}")
async def photo_get(name: str):
    if not _PHOTO_RE.fullmatch(name):
        raise HTTPException(status_code=400, detail="bad photo name")
    path = PHOTO_DIR / name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="photo not found")
    return FileResponse(path, media_type="image/jpeg")


if not WEB_DIR.is_dir():
    raise SystemExit(f"web frontend missing: {WEB_DIR}")

app.mount("/assets", StaticFiles(directory=WEB_DIR / "assets"), name="assets")
app.mount("/vendor", StaticFiles(directory=WEB_DIR / "vendor"), name="vendor")
app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
