"""Calendar REST endpoints.

Local web: CALENDAR_TOKEN may be empty, then these routes are open.
If CALENDAR_TOKEN is set (recommended for any public tunnel), every
protected route still goes through Depends(_require_calendar_token).
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Optional

from fastapi import (
    APIRouter, Body, Depends, File, Header, HTTPException, Query, Request, UploadFile,
)
from fastapi.responses import FileResponse

import config
from calendar_core import (
    CalendarDelivery,
    Storage,
    add_comment,
    complete_calendar_delivery,
    add_note,
    create_event,
    delete_event,
    delete_note,
    get_event,
    get_note,
    list_events,
    list_notes,
    list_unseen_days,
    mark_day_seen,
    render_env_block,
    update_event,
    update_note,
)

router = APIRouter(prefix="/calendar", tags=["calendar"])


def get_storage(request: Request) -> Storage:
    return request.app.state.storage


async def _require_calendar_token(
    x_calendar_token: str = Header("", alias="X-Calendar-Token"),
) -> None:
    expected = config.CALENDAR_TOKEN
    if not expected:
        return
    if not x_calendar_token or x_calendar_token != expected:
        raise HTTPException(status_code=401, detail="invalid calendar token")


@router.get("/events", dependencies=[Depends(_require_calendar_token)])
async def calendar_list(
    request: Request,
    date: Optional[str] = None,
    at: Optional[str] = None,
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = None,
    new_only: bool = False,
    limit: int = 200,
) -> dict[str, Any]:
    try:
        events = await list_events(
            get_storage(request),
            date_value=date,
            at=at,
            from_value=from_,
            to_value=to,
            new_only=new_only,
            limit=limit,
        )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"events": events, "count": len(events)}


@router.get("/events/{event_id}", dependencies=[Depends(_require_calendar_token)])
async def calendar_get(request: Request, event_id: str) -> dict[str, Any]:
    event = await get_event(get_storage(request), event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="event not found")
    return event


@router.post("/events", dependencies=[Depends(_require_calendar_token)])
async def calendar_create(
    request: Request,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    try:
        return await create_event(
            get_storage(request), payload, actor="kitty", source="manual")
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.patch("/events/{event_id}", dependencies=[Depends(_require_calendar_token)])
async def calendar_update(
    request: Request,
    event_id: str,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    try:
        return await update_event(
            get_storage(request), event_id, payload,
            actor="kitty", source="manual")
    except ValueError as exc:
        code = 404 if str(exc) == "event not found" else 400
        raise HTTPException(status_code=code, detail=str(exc)) from exc


@router.delete("/events/{event_id}", dependencies=[Depends(_require_calendar_token)])
async def calendar_delete(request: Request, event_id: str) -> dict[str, Any]:
    try:
        return await delete_event(
            get_storage(request), event_id, actor="kitty", source="manual")
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/events/{event_id}/comments", dependencies=[Depends(_require_calendar_token)])
async def calendar_comment(
    request: Request,
    event_id: str,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    try:
        return await add_comment(
            get_storage(request), event_id,
            str(payload.get("comment") or payload.get("body") or ""),
            author="kitty",
        )
    except ValueError as exc:
        code = 404 if str(exc) == "event not found" else 400
        raise HTTPException(status_code=code, detail=str(exc)) from exc


@router.get("/ping")
async def calendar_ping() -> dict[str, Any]:
    """不查 token 的探活口。部署完先用它确认路由通了，不泄露任何数据。"""
    return {"ok": True, "service": "calendar", "token_required": bool(config.CALENDAR_TOKEN)}


# ============================================================
# 环境块 —— 「此刻日历上有什么」
#
# 有自己聊天管道的人用这个：每轮组装上下文的时候取一次，把 text 贴进
# system prompt 或者环境注入块。下午五点到六点有个牙医，这段时间里
# AI 每一轮都会在自己的上下文里看到「[NOW] 17:00–18:00 看牙医」。
#
# 详见 calendar_core.render_env_block
# ============================================================


@router.get("/env", dependencies=[Depends(_require_calendar_token)])
async def calendar_env(
    request: Request,
    new: bool = True,
) -> dict[str, Any]:
    """?new=false 只出 [NOW] 和 [TODAY]。

    取的时候不标已读：注入这一步可能失败，失败了不该把「用户改了什么」白白销掉。
    拿到之后确认这段文字真的用上了，再拿返回里的 change_ids 调 POST /env/seen
    """
    storage = get_storage(request)
    delivery = await render_env_block(storage, include_new=new)
    return {
        "text": delivery.text,
        "change_ids": list(delivery.change_ids),
        "empty": not delivery.text,
    }


@router.post("/env/seen", dependencies=[Depends(_require_calendar_token)])
async def calendar_env_seen(
    request: Request,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    """把上一次 /env 报出去的那批 [NEW] 标成已读，下一轮就不再重复出现。"""
    raw = payload.get("change_ids")
    if not isinstance(raw, list):
        raise HTTPException(status_code=400, detail="change_ids must be a list")
    try:
        ids = tuple(int(x) for x in raw)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="change_ids must be integers") from exc
    await complete_calendar_delivery(
        get_storage(request), CalendarDelivery(change_ids=ids, channel="env"))
    return {"ok": True, "marked": len(ids)}


# ============================================================
# 便签 —— 手机端「撕下来的一张纸」
#
# 挂在某条日程上（event_id 有值）和贴在一整天上（event_id 为空）是同一件事，
# 走同一组端点。anchor_date 永远有值 = 这张纸贴在哪一页上。
#
# AI 侧的 POST /events/{id}/comments 保留不动，calendar tool 还在用它
# ============================================================


@router.get("/notes", dependencies=[Depends(_require_calendar_token)])
async def notes_list(
    request: Request,
    date: Optional[str] = None,
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = None,
    limit: int = 500,
) -> dict[str, Any]:
    try:
        notes = await list_notes(
            get_storage(request),
            date_value=date, from_value=from_, to_value=to, limit=limit,
        )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"notes": notes, "count": len(notes)}


@router.get("/notes/{note_id}", dependencies=[Depends(_require_calendar_token)])
async def notes_get(request: Request, note_id: str) -> dict[str, Any]:
    note = await get_note(get_storage(request), note_id)
    if note is None or note.get("deleted_at"):
        raise HTTPException(status_code=404, detail="note not found")
    return note


@router.post("/notes", dependencies=[Depends(_require_calendar_token)])
async def notes_create(
    request: Request,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    try:
        return await add_note(
            get_storage(request),
            body=str(payload.get("body") or payload.get("comment") or ""),
            author="kitty",
            event_id=payload.get("event_id") or None,
            anchor_date=payload.get("anchor_date"),
            y=payload.get("y"),
        )
    except (TypeError, ValueError) as exc:
        code = 404 if str(exc) == "event not found" else 400
        raise HTTPException(status_code=code, detail=str(exc)) from exc


@router.patch("/notes/{note_id}", dependencies=[Depends(_require_calendar_token)])
async def notes_update(
    request: Request,
    note_id: str,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    try:
        return await update_note(
            get_storage(request), note_id, payload, actor="kitty")
    except (TypeError, ValueError) as exc:
        code = 404 if str(exc) in ("note not found", "event not found") else 400
        raise HTTPException(status_code=code, detail=str(exc)) from exc


@router.delete("/notes/{note_id}", dependencies=[Depends(_require_calendar_token)])
async def notes_delete(request: Request, note_id: str) -> dict[str, Any]:
    try:
        return await delete_note(get_storage(request), note_id, actor="kitty")
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


# ============================================================
# 感叹号 —— AI 侧在某一页改过东西、用户还没点进去看
#
# 后端原来那套 NEW 是反方向的（用户改了、AI 侧还没读，consumer='master'），
# 这两个口走的是镜像的另一条：consumer='kitty'。两条并存，互不干扰。
#
# GET /unseen 故意不收 from/to：用户前端那份未读是一个扁平集合、整份替换，
# 按月返回会在翻月的时候把别的月的感叹号一起抹掉。未读量现实里就几条，全量给最省事
# ============================================================


@router.get("/unseen", dependencies=[Depends(_require_calendar_token)])
async def calendar_unseen(request: Request) -> dict[str, Any]:
    days = await list_unseen_days(get_storage(request))
    return {"days": days, "count": len(days)}


@router.post("/unseen/seen", dependencies=[Depends(_require_calendar_token)])
async def calendar_unseen_seen(
    request: Request,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    """某一天看过了。天然幂等 —— 同一天打第二遍返回 cleared=0，不报错"""
    try:
        cleared = await mark_day_seen(
            get_storage(request),
            payload.get("date") or payload.get("day"),
        )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "cleared": cleared}


# ============================================================
# 整页图 —— 手机把日视图那一页渲染成 PNG 传上来，给 AI 侧看
#
# 一天只留最新一张，覆盖写。文件躺在 CALENDAR_PAGES_DIR/<日期>.png，
# 不进数据库 —— 没有表、没有迁移，删掉整个目录就回到没有这功能的样子。
# 手机端的触发时机：退回月视图 / 切后台，且那天真的动过（dirty 标记）。
# ============================================================

_PAGES_DIR = Path(config.PAGES_DIR)
_PAGE_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
# 上限跟模型上游的单图限制（约 5MB）对齐着留余量：base64 还要涨三分之一，
# 放行 8MB 会出现「传得上去、see 必炸」的稳定坏状态。实测一页几百 KB，4MB 天花板够高
_PAGE_MAX_BYTES = 4 * 1024 * 1024
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _page_path(date: str) -> Path:
    """先验日期形状再拼路径。不合形状直接 400 —— 这里的 date 会落到文件名上，
    放任意字符串过去等于让人往磁盘上写任意路径。
    必须 fullmatch：match + $ 会放过尾部一个换行（%0A），写出带换行的孤儿文件"""
    if not _PAGE_DATE_RE.fullmatch(date):
        raise HTTPException(status_code=400, detail="date must be YYYY-MM-DD")
    return _PAGES_DIR / f"{date}.png"


@router.post("/pages/{date}/render", dependencies=[Depends(_require_calendar_token)])
async def calendar_page_upload(
    date: str,
    file: UploadFile = File(...),
) -> dict[str, Any]:
    target = _page_path(date)
    # 分块读，超限当场掐断 —— 先整只吞进内存再量大小，等于放任意大的 body 占内存
    chunks: list[bytes] = []
    size = 0
    while True:
        chunk = await file.read(1 << 20)
        if not chunk:
            break
        size += len(chunk)
        if size > _PAGE_MAX_BYTES:
            raise HTTPException(status_code=413, detail="page image too large")
        chunks.append(chunk)
    data = b"".join(chunks)
    if not data:
        raise HTTPException(status_code=400, detail="empty file")
    if not data.startswith(_PNG_MAGIC):
        raise HTTPException(status_code=400, detail="not a png")
    _PAGES_DIR.mkdir(parents=True, exist_ok=True)
    # 唯一临时名 + 原子换名：GET 永远只读到完整的一张。临时名里带随机段是因为
    # 固定名会让并发的同日上传互相 truncate 对方写到一半的文件，后 replace 的是最终版；
    # 写失败连自己的临时文件一起收走，磁盘满也不留孤儿
    tmp = _PAGES_DIR / f".{date}.{os.urandom(8).hex()}.tmp"
    try:
        tmp.write_bytes(data)
        tmp.replace(target)
    except OSError:
        tmp.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail="failed to store page")
    return {"ok": True, "date": date, "size": len(data)}


@router.get("/pages/{date}/render", dependencies=[Depends(_require_calendar_token)])
async def calendar_page_get(date: str) -> FileResponse:
    target = _page_path(date)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="no page for this date")
    return FileResponse(target, media_type="image/png")
