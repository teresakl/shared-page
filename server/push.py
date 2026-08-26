"""可选推送模块：AI 侧动了日历，手机上的日历 app 弹一条原生通知。

需要付费开发者账号 + 自己的 APNs Auth Key（.p8）。四个环境变量缺任何一个，
整个模块自动关闭：/push/register 返回 503 + 说明，发送函数静默 no-op，
其余功能一切照常 —— 只是伴侣动日历的时候手机不响。

  APNS_KEY_PATH   .p8 私钥文件路径（Auth Key 对 sandbox / production 通用）
  APNS_KEY_ID     那把钥匙的 Key ID
  APNS_TEAM_ID    开发者 Team ID
  APNS_BUNDLE_ID  日历 app 的 bundle id（登记口只收它，别人的 token 不收）

可选依赖同理：httpx[http2] / PyJWT / cryptography 只有真发推送才需要，
没装也不影响服务启动（import 全在函数里）。
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
import uuid
from pathlib import Path
from typing import Any, Literal, Optional

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field, ValidationError, field_validator

import config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/calendar/push", tags=["push"])


def enabled() -> bool:
    """APNS_* 四件齐了才算开。缺任何一件都当没有这个模块。"""
    return bool(
        config.APNS_KEY_PATH
        and config.APNS_KEY_ID
        and config.APNS_TEAM_ID
        and config.APNS_BUNDLE_ID
    )


# ============================================================
# push_devices 表 —— app 端把 APNs device token 登记进来
# ============================================================

PUSH_DDL = """
CREATE TABLE IF NOT EXISTS push_devices (
  id            TEXT PRIMARY KEY,
  device_id     TEXT NOT NULL,
  transport     TEXT NOT NULL,
  platform      TEXT NOT NULL,
  bundle_id     TEXT NOT NULL,
  environment   TEXT NOT NULL,
  device_token  TEXT NOT NULL,
  app_version   TEXT,
  app_build     TEXT,
  device_label  TEXT,
  enabled       INTEGER NOT NULL DEFAULT 1,
  last_seen_at  TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  UNIQUE(device_id, transport, bundle_id, environment)
);
CREATE INDEX IF NOT EXISTS idx_push_devices_active
  ON push_devices(platform, transport, bundle_id, environment, enabled);
CREATE INDEX IF NOT EXISTS idx_push_devices_token
  ON push_devices(transport, bundle_id, environment, device_token);
"""


async def ensure_push_schema(conn) -> None:
    await conn.executescript(PUSH_DDL)
    await conn.commit()


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


async def upsert_device(
    conn,
    *,
    device_id: str,
    transport: str,
    platform: str,
    bundle_id: str,
    environment: str,
    device_token: str,
    app_version: str = "",
    app_build: str = "",
    device_label: str = "",
    enabled_flag: bool = True,
) -> str:
    now = _now_iso()
    async with conn.execute(
        "SELECT id FROM push_devices "
        "WHERE device_id=? AND transport=? AND bundle_id=? AND environment=?",
        (device_id, transport, bundle_id, environment),
    ) as cur:
        row = await cur.fetchone()

    if row:
        target_id = str(row["id"])
        await conn.execute(
            "UPDATE push_devices SET platform=?, device_token=?, "
            "app_version=?, app_build=?, device_label=?, enabled=?, "
            "last_seen_at=?, updated_at=? WHERE id=?",
            (
                platform, device_token, app_version, app_build,
                device_label, 1 if enabled_flag else 0, now, now, target_id,
            ),
        )
    else:
        target_id = f"pdt_{uuid.uuid4().hex[:16]}"
        await conn.execute(
            "INSERT INTO push_devices("
            "id, device_id, transport, platform, bundle_id, environment, "
            "device_token, app_version, app_build, device_label, enabled, "
            "last_seen_at, created_at, updated_at"
            ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                target_id, device_id, transport, platform, bundle_id,
                environment, device_token, app_version, app_build,
                device_label, 1 if enabled_flag else 0, now, now, now,
            ),
        )

    # 恢复出厂 / 换机之后 APNs 可能把同一个 token 还给新 device_id。
    # 同一个 token 只留一条活记录，免得一条改动弹两声
    await conn.execute(
        "UPDATE push_devices SET enabled=0, updated_at=? "
        "WHERE transport=? AND bundle_id=? AND environment=? "
        "AND device_token=? AND id<>? AND enabled<>0",
        (now, transport, bundle_id, environment, device_token, target_id),
    )
    # Debug 版和 TestFlight 版共用 bundle id、装不进同一台手机：
    # 最近登记的那个环境是活的，另一个环境的旧登记灭掉
    await conn.execute(
        "UPDATE push_devices SET enabled=0, updated_at=? "
        "WHERE device_id=? AND transport=? AND bundle_id=? "
        "AND environment<>? AND id<>? AND enabled<>0",
        (now, device_id, transport, bundle_id, environment, target_id),
    )
    await conn.commit()
    return target_id


async def list_active_devices(conn, *, bundle_id: str) -> list[dict[str, Any]]:
    async with conn.execute(
        "SELECT id, device_id, transport, platform, bundle_id, "
        "environment, device_token, app_version, app_build, device_label "
        "FROM push_devices WHERE enabled<>0 AND platform='ios' "
        "AND bundle_id=? AND transport='apns' "
        "ORDER BY last_seen_at DESC",
        (bundle_id,),
    ) as cur:
        rows = await cur.fetchall()
    return [dict(r) for r in rows]


# ============================================================
# 登记端点 —— POST /calendar/push/register
#
# 挂在 /calendar 前缀下、用同一个 X-Calendar-Token 鉴权：app 本来就带着钥匙，
# 零新凭据。bundle 钉死 APNS_BUNDLE_ID，别人的 token 不收
# ============================================================


class APNsRegistrationRequest(BaseModel):
    device_id: str = Field(min_length=8, max_length=128)
    transport: Literal["apns"] = "apns"
    platform: Literal["ios"] = "ios"
    bundle_id: str = Field(min_length=3, max_length=255)
    environment: Literal["sandbox", "production"]
    device_token: str = Field(min_length=32, max_length=512)
    app_version: str = Field(default="", max_length=64)
    app_build: str = Field(default="", max_length=64)
    device_label: str = Field(default="", max_length=120)
    enabled: bool = True

    @field_validator("device_id", "bundle_id")
    @classmethod
    def strip_identifier(cls, value: str) -> str:
        return value.strip()

    @field_validator("device_token")
    @classmethod
    def normalize_device_token(cls, value: str) -> str:
        token = value.strip().lower()
        if len(token) % 2 or not re.fullmatch(r"[0-9a-f]+", token):
            raise ValueError("device_token must be lowercase hexadecimal")
        return token


async def _require_calendar_token(
    x_calendar_token: str = Header("", alias="X-Calendar-Token"),
) -> None:
    expected = config.CALENDAR_TOKEN
    if not expected:
        return
    if not x_calendar_token or x_calendar_token != expected:
        raise HTTPException(status_code=401, detail="invalid calendar token")


@router.post("/register", dependencies=[Depends(_require_calendar_token)])
async def calendar_push_register(
    request: Request,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    if not enabled():
        raise HTTPException(
            status_code=503,
            detail=(
                "push is not configured on this server. Set APNS_KEY_PATH, "
                "APNS_KEY_ID, APNS_TEAM_ID and APNS_BUNDLE_ID to enable APNs; "
                "everything else works without it."
            ),
        )
    try:
        body = APNsRegistrationRequest(
            **{**payload, "transport": "apns", "platform": "ios"})
    except ValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)[:300]) from exc
    if body.bundle_id != config.APNS_BUNDLE_ID:
        raise HTTPException(status_code=400, detail="unexpected bundle for calendar push")
    target_id = await upsert_device(
        request.app.state.storage._conn,
        device_id=body.device_id,
        transport=body.transport,
        platform=body.platform,
        bundle_id=body.bundle_id,
        environment=body.environment,
        device_token=body.device_token,
        app_version=body.app_version,
        app_build=body.app_build,
        device_label=body.device_label,
        enabled_flag=body.enabled,
    )
    return {"ok": True, "target_id": target_id, "environment": body.environment}


# ============================================================
# APNs provider —— HTTP/2 直连苹果，ES256 provider token 缓存 50 分钟
#
# sandbox / production 按登记时的 environment 分流（Auth Key 两边通用，
# 只是接的主机不同）。发送失败只记日志，绝不往上抛
# ============================================================


class APNsProvider:
    def __init__(self) -> None:
        self._token: str = ""
        self._issued_at: int = 0
        self._token_lock = asyncio.Lock()
        self._clients: dict[str, Any] = {}

    async def send_alert(
        self,
        *,
        device_token: str,
        environment: str,
        title: str,
        preview: str,
        payload_data: Optional[dict[str, Any]] = None,
        collapse_id: str = "",
    ) -> dict[str, Any]:
        if environment not in {"sandbox", "production"}:
            return {"sent": False, "reason": "invalid_environment"}

        payload: dict[str, Any] = {
            "aps": {
                "alert": {"title": (title or "Calendar")[:80], "body": preview[:180]},
                "sound": "default",
                "category": "CALENDAR_CHANGE",
            },
        }
        if payload_data:
            payload.update({
                str(key): value
                for key, value in payload_data.items()
                if str(key) != "aps"
            })
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(body) > 4096:
            return {"sent": False, "reason": "payload_too_large"}

        endpoint = (
            "https://api.sandbox.push.apple.com"
            if environment == "sandbox"
            else "https://api.push.apple.com"
        )
        url = f"{endpoint}/3/device/{device_token}"

        for attempt in range(2):
            try:
                provider_token = await self._authorization_token(force_refresh=attempt > 0)
                headers = {
                    "authorization": f"bearer {provider_token}",
                    "apns-topic": config.APNS_BUNDLE_ID,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                    "apns-expiration": "0",
                    "content-type": "application/json",
                }
                if collapse_id:
                    headers["apns-collapse-id"] = collapse_id[:64]
                response = await self._client(environment).post(
                    url, content=body, headers=headers)
            except Exception as exc:
                logger.warning("APNs request failed before response: %s", type(exc).__name__)
                return {"sent": False, "reason": f"network_error:{type(exc).__name__}"}

            if response.status_code == 200:
                return {"sent": True, "status_code": 200}

            reason = self._response_reason(response)
            # provider token 过期 / 失效：清缓存重签一次再试
            if (attempt == 0 and response.status_code == 403
                    and reason in {"ExpiredProviderToken", "InvalidProviderToken"}):
                async with self._token_lock:
                    self._token = ""
                    self._issued_at = 0
                continue
            return {
                "sent": False,
                "status_code": response.status_code,
                "reason": reason or f"http_{response.status_code}",
                # 410 / Unregistered = 这个 token 死了（app 卸了或换机）
                "invalid_token": response.status_code == 410 or reason == "Unregistered",
            }
        return {"sent": False, "reason": "provider_token_rejected"}

    async def close(self) -> None:
        clients = list(self._clients.values())
        self._clients.clear()
        for client in clients:
            await client.aclose()

    def _client(self, environment: str):
        import httpx
        client = self._clients.get(environment)
        if client is None:
            client = httpx.AsyncClient(
                http2=True,
                timeout=httpx.Timeout(connect=10.0, read=15.0, write=10.0, pool=10.0),
                limits=httpx.Limits(max_connections=10, max_keepalive_connections=4),
            )
            self._clients[environment] = client
        return client

    async def _authorization_token(self, force_refresh: bool = False) -> str:
        import jwt
        now = int(time.time())
        # 苹果要求 provider token 20-60 分钟一换，取 50 分钟续签
        if not force_refresh and self._token and now - self._issued_at < 50 * 60:
            return self._token
        async with self._token_lock:
            now = int(time.time())
            if not force_refresh and self._token and now - self._issued_at < 50 * 60:
                return self._token
            private_key = await asyncio.to_thread(
                Path(config.APNS_KEY_PATH).read_text, encoding="utf-8")
            encoded = jwt.encode(
                {"iss": config.APNS_TEAM_ID, "iat": now},
                private_key,
                algorithm="ES256",
                headers={"kid": config.APNS_KEY_ID},
            )
            self._token = encoded.decode("ascii") if isinstance(encoded, bytes) else encoded
            self._issued_at = now
            return self._token

    @staticmethod
    def _response_reason(response) -> str:
        try:
            payload = response.json()
        except Exception:
            return ""
        reason = payload.get("reason") if isinstance(payload, dict) else ""
        return str(reason or "")


_provider: Optional[APNsProvider] = None


def get_provider() -> APNsProvider:
    global _provider
    if _provider is None:
        _provider = APNsProvider()
    return _provider


async def send_calendar_alert(storage, *, title: str, body: str, day: str) -> None:
    """calendar_core._push_calendar_change 调这里。没配 / 没登记 token = 静默跳过。

    payload 带 calendar_day，app 点开通知直接翻到那一页；
    同一天连着改用 collapse id 收成最新一条
    """
    if not enabled():
        return
    targets = await list_active_devices(storage._conn, bundle_id=config.APNS_BUNDLE_ID)
    if not targets:
        return
    provider = get_provider()
    for t in targets:
        result = await provider.send_alert(
            device_token=str(t["device_token"]),
            environment=str(t["environment"]),
            title=title,
            preview=body,
            payload_data={"calendar_day": day} if day else None,
            collapse_id=f"cal-{day}" if day else f"cal-{uuid.uuid4().hex[:8]}",
        )
        logger.info("calendar push day=%s -> %s", day, result)
