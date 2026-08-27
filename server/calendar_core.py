"""Shared calendar storage, rendering, and tool execution.

Calendar state is global.  The REST API (routes.py) and the MCP server
(mcp_server.py) use this same core.  All stored timestamps are UTC ISO
strings.  Human-facing dates use the configured product timezone
(CALENDAR_TZ, default Asia/Shanghai).
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import uuid

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from zoneinfo import ZoneInfo

import aiosqlite

import config

logger = logging.getLogger(__name__)

# 全服务一个产品时区。名字沿用生产版的 _BJ（北京），值跟着 CALENDAR_TZ 走
_BJ = ZoneInfo(config.CALENDAR_TZ)
_LOCK = asyncio.Lock()
_SCHEMA_LOCK = asyncio.Lock()
_CONSUMER = "master"
_KITTY_CONSUMER = "kitty"   # 反方向：AI 侧改了、用户还没点进那一页看

CALENDAR_DDL = """
CREATE TABLE IF NOT EXISTS calendar_events (
  id                TEXT PRIMARY KEY,
  title             TEXT NOT NULL,
  description       TEXT,
  starts_at         TEXT NOT NULL,
  ends_at           TEXT NOT NULL,
  timezone          TEXT NOT NULL DEFAULT 'Asia/Shanghai',
  precision         TEXT NOT NULL DEFAULT 'hour',
  event_type        TEXT,
  source            TEXT NOT NULL,
  created_by        TEXT NOT NULL,
  source_message_id TEXT,
  revision          INTEGER NOT NULL DEFAULT 1,
  status            TEXT NOT NULL DEFAULT 'active',
  metadata          JSON,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  deleted_at        TEXT
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_span
  ON calendar_events(status, starts_at, ends_at);
CREATE INDEX IF NOT EXISTS idx_calendar_events_source_message
  ON calendar_events(source_message_id);

CREATE TABLE IF NOT EXISTS calendar_event_changes (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id       TEXT NOT NULL,
  event_revision INTEGER NOT NULL,
  action         TEXT NOT NULL,
  actor          TEXT NOT NULL,
  source         TEXT NOT NULL,
  snapshot       JSON NOT NULL,
  notify_master  INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_calendar_changes_event
  ON calendar_event_changes(event_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_calendar_changes_notify
  ON calendar_event_changes(notify_master, id);

CREATE TABLE IF NOT EXISTS calendar_change_receipts (
  change_id  INTEGER NOT NULL,
  consumer   TEXT NOT NULL,
  state      TEXT NOT NULL DEFAULT 'unseen',
  seen_at    TEXT,
  channel    TEXT,
  PRIMARY KEY (change_id, consumer),
  FOREIGN KEY (change_id) REFERENCES calendar_event_changes(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_calendar_receipts_unseen
  ON calendar_change_receipts(consumer, state, change_id);

-- 便签（手机端叫「撕下来的一张纸」）。挂在某条日程上是它，贴在一整天上也是它。
-- event_id 可空 = 贴在这一天、不关于任何日程；anchor_date 永远有值 = 这张纸贴在哪一页上。
-- 外键是 SET NULL 不是 CASCADE：删掉一条日程，贴在它上面的便签留着，只解开关联 ——
-- 跟前端 CalendarStore.delete(_:on:) 的行为对齐，那边是对的
CREATE TABLE IF NOT EXISTS calendar_comments (
  id          TEXT PRIMARY KEY,
  event_id    TEXT,
  anchor_date TEXT NOT NULL,
  author      TEXT NOT NULL,
  body        TEXT NOT NULL,
  y           REAL,
  liked       INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT,
  FOREIGN KEY (event_id) REFERENCES calendar_events(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_calendar_comments_event
  ON calendar_comments(event_id, created_at);
CREATE INDEX IF NOT EXISTS idx_calendar_comments_date
  ON calendar_comments(anchor_date, deleted_at);

-- 生产版遗留的形状，开源版允许它一直空着：complete_calendar_delivery 只有
-- conversation 粒度的调用方才会写它，MCP/REST 这两条路都不带 conversation_id
CREATE TABLE IF NOT EXISTS calendar_consumer_state (
  consumer           TEXT NOT NULL,
  conversation_id    TEXT NOT NULL,
  last_now_signature TEXT NOT NULL DEFAULT '',
  updated_at         TEXT NOT NULL,
  PRIMARY KEY (consumer, conversation_id)
);
"""


class Storage:
    """最薄的一层：只负责连库和建表。

    核心函数的签名跟生产版一致 —— 都收一个带 ``_conn``（aiosqlite 连接）的
    storage 对象，所以这里只要把连接挂在 ``_conn`` 上，其余函数一个签名都不用动。
    REST 进程和 MCP 进程可能同时开着同一个库文件，所以走 WAL + busy_timeout。
    """

    def __init__(self, db_path: str) -> None:
        self.db_path = Path(db_path)
        self._conn: Optional[aiosqlite.Connection] = None
        self._calendar_schema_ready = False

    async def connect(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = await aiosqlite.connect(self.db_path)
        self._conn.row_factory = aiosqlite.Row
        await self._conn.execute("PRAGMA journal_mode=WAL")
        await self._conn.execute("PRAGMA busy_timeout=5000")
        await ensure_calendar_schema(self)

    async def close(self) -> None:
        if self._conn is not None:
            await self._conn.close()
            self._conn = None
            self._calendar_schema_ready = False


@dataclass
class CalendarDelivery:
    text: str = ""
    change_ids: tuple[int, ...] = ()
    conversation_id: Optional[str] = None
    now_signature: Optional[str] = None
    channel: str = ""


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds")


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


def _parse_datetime(raw: Any, *, assume_bj: bool = True) -> datetime:
    text = str(raw or "").strip()
    if not text:
        raise ValueError("time is required")
    if len(text) == 10:
        value = datetime.combine(date.fromisoformat(text), time.min, tzinfo=_BJ)
    else:
        value = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=_BJ if assume_bj else timezone.utc)
    return value.astimezone(timezone.utc)


def _normalise_times(payload: dict[str, Any]) -> tuple[datetime, datetime, str]:
    raw_start = payload.get("starts_at") or payload.get("start")
    start_text = str(raw_start or "").strip()
    start = _parse_datetime(start_text)
    precision = str(payload.get("precision") or "").strip().lower()
    if precision not in {"minute", "hour", "segment", "day"}:
        precision = "day" if len(start_text) == 10 else "hour"
    raw_end = payload.get("ends_at") or payload.get("end")
    if raw_end:
        end = _parse_datetime(raw_end)
    else:
        end = start + (timedelta(days=1) if precision == "day" else timedelta(hours=1))
    if end <= start:
        raise ValueError("ends_at must be later than starts_at")
    return start, end, precision


def _row_event(row: Any) -> dict[str, Any]:
    data = dict(row)
    raw = data.get("metadata")
    if isinstance(raw, str) and raw:
        try:
            data["metadata"] = json.loads(raw)
        except json.JSONDecodeError:
            pass
    return data


async def _fetchall(conn, sql: str, params: tuple[Any, ...] = ()) -> list[Any]:
    async with conn.execute(sql, params) as cur:
        return list(await cur.fetchall())


async def _fetchone(conn, sql: str, params: tuple[Any, ...] = ()) -> Any:
    async with conn.execute(sql, params) as cur:
        return await cur.fetchone()


def _anchor_date_of(value: Optional[str]) -> Optional[str]:
    """ISO 时刻 → 产品时区的自然日 "2026-08-25"。解不动返回 None。
    纯计算不碰 IO，所以是同步的 —— _normalise_anchor 也要用它"""
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(_BJ).date().isoformat()


async def _migrate_comments_v2(conn) -> bool:
    """便签表升级：event_id 放开可空、加 anchor_date / y / liked、外键改 SET NULL。

    SQLite 改不了列的可空性和外键，只能整表重建。这一步必须跑在 CALENDAR_DDL 前面 ——
    新的 anchor_date 索引在老表上建不出来。跑过一次之后是纯 no-op。
    （全新部署永远走不进来，留着它是为了从老库结构平滑升级）
    """
    cur = await conn.execute("PRAGMA table_info(calendar_comments)")
    cols = [row[1] for row in await cur.fetchall()]
    if not cols:
        return False                      # 全新库，等下面的 DDL 直接建新表
    if "anchor_date" in cols:
        return False                      # 已经升级过了

    logger.info("calendar: migrating calendar_comments to v2 (anchor_date / y / liked)")
    # 整段包进一条事务：中途崩掉要么全成要么全不成。
    # 没有它的话，崩在 ALTER 和 CREATE 之间会留下「老表叫 v1、新表不存在」的半截状态，
    # 下次启动 init_schema 用老 DDL 把 calendar_comments 凭空重建出来，迁移再想改名就撞 v1，
    # 抛 OperationalError 穿透到上层 → REST 全线 500、calendar tool 全线报错，要人手进库救
    await conn.execute("BEGIN IMMEDIATE")
    cur = await conn.execute(
        "SELECT c.id, c.event_id, c.author, c.body, c.created_at, c.updated_at, "
        "       c.deleted_at, e.starts_at "
        "FROM calendar_comments c LEFT JOIN calendar_events e ON e.id = c.event_id"
    )
    rows = await cur.fetchall()

    # 索引跟着表走：RENAME 会把 idx_calendar_comments_event 一起带到 v1 上去，
    # 之后 CALENDAR_DDL 里那句 CREATE INDEX IF NOT EXISTS 因为重名被静默跳过，
    # 新表就永远没有这个索引了。先删掉再改名
    await conn.execute("DROP INDEX IF EXISTS idx_calendar_comments_event")
    await conn.execute("DROP INDEX IF EXISTS idx_calendar_comments_date")
    await conn.execute("ALTER TABLE calendar_comments RENAME TO calendar_comments_v1")
    await conn.execute(
        """CREATE TABLE calendar_comments (
  id          TEXT PRIMARY KEY,
  event_id    TEXT,
  anchor_date TEXT NOT NULL,
  author      TEXT NOT NULL,
  body        TEXT NOT NULL,
  y           REAL,
  liked       INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT,
  FOREIGN KEY (event_id) REFERENCES calendar_events(id) ON DELETE SET NULL
)"""
    )
    moved = 0
    for r in rows:
        cid, event_id, author, body, created_at, updated_at, deleted_at, starts_at = r
        # 挂在日程上的，anchor 就是那条日程那天；挂不上的退回它自己被写下来的那天
        anchor = _anchor_date_of(starts_at) or _anchor_date_of(created_at)
        if not anchor:
            anchor = datetime.now(_BJ).date().isoformat()
        await conn.execute(
            "INSERT INTO calendar_comments"
            "(id,event_id,anchor_date,author,body,y,liked,created_at,updated_at,deleted_at) "
            "VALUES(?,?,?,?,?,NULL,0,?,?,?)",
            (cid, event_id, anchor, author, body, created_at, updated_at, deleted_at),
        )
        moved += 1
    await conn.execute("COMMIT")
    # 老表留着不删，出事随时能捞回来。占不了多少地方
    logger.info("calendar: calendar_comments v2 migration done, moved %s rows", moved)
    return True


async def ensure_calendar_schema(storage) -> None:
    if bool(getattr(storage, "_calendar_schema_ready", False)):
        return
    conn = storage._conn
    if conn is None:
        raise RuntimeError("storage is not connected")
    async with _SCHEMA_LOCK:
        if bool(getattr(storage, "_calendar_schema_ready", False)):
            return
        await _migrate_comments_v2(conn)      # 必须在 DDL 之前，见函数注释
        await conn.executescript(CALENDAR_DDL)
        await conn.commit()
        storage._calendar_schema_ready = True


async def _insert_change(
    conn,
    *,
    event: dict[str, Any],
    action: str,
    actor: str,
    source: str,
    notify_master: bool,
    notify_kitty: bool = False,
) -> int:
    cur = await conn.execute(
        "INSERT INTO calendar_event_changes("
        "event_id,event_revision,action,actor,source,snapshot,notify_master,created_at"
        ") VALUES(?,?,?,?,?,?,?,?)",
        (
            event["id"], int(event.get("revision") or 1), action, actor, source,
            _json(event), 1 if notify_master else 0, _iso(_now()),
        ),
    )
    change_id = int(cur.lastrowid)
    if notify_master:
        await conn.execute(
            "INSERT OR IGNORE INTO calendar_change_receipts(change_id,consumer,state) "
            "VALUES(?,?, 'unseen')",
            (change_id, _CONSUMER),
        )
    if notify_kitty:
        await conn.execute(
            "INSERT OR IGNORE INTO calendar_change_receipts(change_id,consumer,state) "
            "VALUES(?,?, 'unseen')",
            (change_id, _KITTY_CONSUMER),
        )
    return change_id


async def get_event(storage, event_id: str) -> Optional[dict[str, Any]]:
    await ensure_calendar_schema(storage)
    row = await _fetchone(
        storage._conn, "SELECT * FROM calendar_events WHERE id=?", (event_id,),
    )
    if row is None:
        return None
    event = _row_event(row)
    comments = await _fetchall(
        storage._conn,
        "SELECT id,event_id,author,body,created_at,updated_at "
        "FROM calendar_comments WHERE event_id=? AND deleted_at IS NULL "
        "ORDER BY created_at",
        (event_id,),
    )
    event["comments"] = [dict(item) for item in comments]
    return event


async def create_event(
    storage,
    payload: dict[str, Any],
    *,
    actor: str,
    source: str = "manual",
    event_id: Optional[str] = None,
    source_message_id: Optional[str] = None,
) -> dict[str, Any]:
    await ensure_calendar_schema(storage)
    title = " ".join(str(payload.get("title") or "").split())[:160]
    if not title:
        raise ValueError("title is required")
    start, end, precision = _normalise_times(payload)
    eid = event_id or f"cal_{uuid.uuid4().hex[:16]}"
    now = _iso(_now())
    metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
    event = {
        "id": eid,
        "title": title,
        "description": str(payload.get("description") or "").strip()[:2000],
        "starts_at": _iso(start),
        "ends_at": _iso(end),
        "timezone": config.CALENDAR_TZ,
        "precision": precision,
        "event_type": str(payload.get("event_type") or "custom").strip()[:60],
        "source": source,
        "created_by": actor,
        "source_message_id": source_message_id,   # 可选的来源追溯字段
        "revision": 1,
        "status": "active",
        "metadata": metadata,
        "created_at": now,
        "updated_at": now,
        "deleted_at": None,
    }
    notify = source == "manual" and actor == "kitty"
    notify_k = source == "manual" and actor == "master"
    async with _LOCK:
        existing = await _fetchone(
            storage._conn, "SELECT * FROM calendar_events WHERE id=?", (eid,),
        )
        if existing is not None:
            current = _row_event(existing)
            current["created"] = False
            return current
        await storage._conn.execute(
            "INSERT INTO calendar_events("
            "id,title,description,starts_at,ends_at,timezone,precision,event_type,"
            "source,created_by,source_message_id,revision,status,metadata,created_at,"
            "updated_at,deleted_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                event["id"], event["title"], event["description"],
                event["starts_at"], event["ends_at"], event["timezone"],
                event["precision"], event["event_type"], event["source"],
                event["created_by"], event["source_message_id"], event["revision"],
                event["status"], _json(metadata), event["created_at"],
                event["updated_at"], event["deleted_at"],
            ),
        )
        await _insert_change(
            storage._conn, event=event, action="create", actor=actor,
            source=source, notify_master=notify, notify_kitty=notify_k,
        )
        await storage._conn.commit()
    event["created"] = True
    return event


async def update_event(
    storage,
    event_id: str,
    payload: dict[str, Any],
    *,
    actor: str,
    source: str = "manual",
) -> dict[str, Any]:
    await ensure_calendar_schema(storage)
    async with _LOCK:
        row = await _fetchone(
            storage._conn,
            "SELECT * FROM calendar_events WHERE id=? AND status='active'",
            (event_id,),
        )
        if row is None:
            raise ValueError("event not found")
        event = _row_event(row)
        prev_span = {"starts_at": event["starts_at"], "ends_at": event["ends_at"]}
        merged = dict(event)
        merged.update({k: v for k, v in payload.items() if v is not None})
        if any(k in payload for k in ("starts_at", "start", "ends_at", "end", "precision")):
            start, end, precision = _normalise_times(merged)
            event["starts_at"], event["ends_at"], event["precision"] = (
                _iso(start), _iso(end), precision,
            )
        if "title" in payload:
            title = " ".join(str(payload.get("title") or "").split())[:160]
            if not title:
                raise ValueError("title is required")
            event["title"] = title
        if "description" in payload:
            event["description"] = str(payload.get("description") or "").strip()[:2000]
        if "event_type" in payload:
            event["event_type"] = str(payload.get("event_type") or "custom")[:60]
        if isinstance(payload.get("metadata"), dict):
            event["metadata"] = payload["metadata"]
        event["revision"] = int(event.get("revision") or 1) + 1
        event["updated_at"] = _iso(_now())
        event["source"] = source
        await storage._conn.execute(
            "UPDATE calendar_events SET title=?,description=?,starts_at=?,ends_at=?,"
            "precision=?,event_type=?,source=?,revision=?,metadata=?,updated_at=? "
            "WHERE id=?",
            (
                event["title"], event.get("description"), event["starts_at"],
                event["ends_at"], event["precision"], event.get("event_type"),
                source, event["revision"], _json(event.get("metadata") or {}),
                event["updated_at"], event_id,
            ),
        )
        # 挪过日子：改之前的跨度一起写进快照，_change_days 会把新旧两边的天都点亮。
        # 快照单独拷一份 —— prev_span 不该混进返回给调用方 / 写回表里的事件本体
        snapshot = dict(event)
        if (event["starts_at"], event["ends_at"]) != (prev_span["starts_at"], prev_span["ends_at"]):
            snapshot["prev_span"] = prev_span
        await _insert_change(
            storage._conn, event=snapshot, action="update", actor=actor,
            source=source, notify_master=(source == "manual" and actor == "kitty"),
            notify_kitty=(source == "manual" and actor == "master"),
        )
        await storage._conn.commit()
    return event


async def delete_event(
    storage,
    event_id: str,
    *,
    actor: str,
    source: str = "manual",
) -> dict[str, Any]:
    await ensure_calendar_schema(storage)
    async with _LOCK:
        row = await _fetchone(
            storage._conn,
            "SELECT * FROM calendar_events WHERE id=? AND status='active'",
            (event_id,),
        )
        if row is None:
            raise ValueError("event not found")
        event = _row_event(row)
        event["revision"] = int(event.get("revision") or 1) + 1
        event["status"] = "deleted"
        event["deleted_at"] = _iso(_now())
        event["updated_at"] = event["deleted_at"]
        event["source"] = source
        await storage._conn.execute(
            "UPDATE calendar_events SET status='deleted',deleted_at=?,updated_at=?,"
            "revision=?,source=? WHERE id=?",
            (
                event["deleted_at"], event["updated_at"], event["revision"],
                source, event_id,
            ),
        )
        await _insert_change(
            storage._conn, event=event, action="delete", actor=actor,
            source=source, notify_master=(source == "manual" and actor == "kitty"),
            notify_kitty=(source == "manual" and actor == "master"),
        )
        await storage._conn.commit()
    return event


# ============================================================
# 便签 —— 手机端叫「撕下来的一张纸」
#
# 两种形态是同一件事：贴在某条日程上（event_id 有值），或者贴在一整天上（event_id 为空）。
# 后者是用户前端的默认状态 —— 撕下来先是不绑的，拖到某条日程上压住了才绑。
#
# AI 侧（calendar 工具）原来那条路一个字节没变：add_comment(event_id, body) 照旧能用，
# 只是内部转到下面这个通用函数，顺手把 anchor_date 从事件那天推出来。
# ============================================================

def _note_row(row: Any) -> dict[str, Any]:
    d = dict(row)
    d["liked"] = bool(d.get("liked"))
    return d


# 前端便签版式的三个定稿数（DayView / TornNoteView）：
# 兜底排布 34 + i×116；一张纸连胶带影子约占 116 高；落纸下限 = 时间轴内容高 1042 - 96
_NOTE_FALLBACK_TOP = 34.0
_NOTE_STEP = 116.0
_NOTE_MAX_Y = 1042.0 - 96.0


async def _next_free_note_y(conn, anchor: str) -> float:
    """master 新纸落在当天所有纸的最下面（两张纸绝不许叠）。

    用户自己摆过的纸都有 y 值；y 是空的老纸按前端同一套兜底（34+i×116）推算。
    取最大占位再往下一格，画布见底就贴着下限 —— 叠在底边也比压住已有的字强
    """
    rows = await _fetchall(
        conn,
        "SELECT y FROM calendar_comments "
        "WHERE anchor_date=? AND deleted_at IS NULL ORDER BY created_at",
        (anchor,),
    )
    bottom = None
    for i, row in enumerate(rows):
        raw = dict(row).get("y")
        occupied = float(raw) if raw is not None else _NOTE_FALLBACK_TOP + i * _NOTE_STEP
        bottom = occupied if bottom is None else max(bottom, occupied)
    if bottom is None:
        return _NOTE_FALLBACK_TOP
    return min(bottom + _NOTE_STEP, _NOTE_MAX_Y)


async def add_note(
    storage,
    *,
    body: str,
    author: str,
    event_id: Optional[str] = None,
    anchor_date: Optional[str] = None,
    y: Optional[float] = None,
) -> dict[str, Any]:
    """写一张便签。挂日程就传 event_id，贴一整天就传 anchor_date，两个都给以 event_id 那天为准。"""
    await ensure_calendar_schema(storage)
    text = " ".join(str(body or "").split())[:2000]
    if not text:
        raise ValueError("comment is required")

    event = None
    if event_id:
        event = await get_event(storage, event_id)
        if event is None or event.get("status") != "active":
            raise ValueError("event not found")
        anchor = _anchor_date_of(event.get("starts_at"))
    else:
        anchor = _normalise_anchor(anchor_date)
    if not anchor:
        raise ValueError("anchor_date is required when event_id is omitted")

    now_iso = _iso(_now())
    if y is None and author == "master":
        # AI 侧的纸不带坐标就自动排到当天最下面，绝不压用户摆好的纸。
        # 用户前端撕的纸永远自带 y，这条只管 master 这一路
        y = await _next_free_note_y(storage._conn, anchor)
    note = {
        "id": f"cmt_{uuid.uuid4().hex[:16]}",
        "event_id": event_id,
        "anchor_date": anchor,
        "author": author,
        "body": text,
        "y": float(y) if y is not None else None,
        "liked": False,
        "created_at": now_iso,
        "updated_at": now_iso,
    }
    async with _LOCK:
        await storage._conn.execute(
            "INSERT INTO calendar_comments"
            "(id,event_id,anchor_date,author,body,y,liked,created_at,updated_at) "
            "VALUES(?,?,?,?,?,?,0,?,?)",
            (note["id"], event_id, anchor, author, text, note["y"], now_iso, now_iso),
        )
        await _insert_note_change(
            storage._conn, note=note, event=event, action="comment", actor=author,
        )
        await storage._conn.commit()
    return note


async def add_comment(
    storage,
    event_id: str,
    body: str,
    *,
    author: str,
) -> dict[str, Any]:
    """老签名，AI 侧的 calendar 工具和 /events/{id}/comments 还在用，行为不变"""
    return await add_note(storage, body=body, author=author, event_id=event_id)


def _normalise_anchor(value: Optional[str]) -> Optional[str]:
    """接受 "2026-08-25" 或者完整 ISO 时刻，一律归到产品时区的自然日。

    带时刻的必须走时区换算，不能截前十个字符了事 —— iOS 的 Date 默认序列化成带 Z 的 UTC，
    北京时间早上八点之后撕的便签，UTC 那边还停在前一天，直接截字符串会整张纸贴错一页
    """
    if not value:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    # 长过纯日期的一律当时刻走时区换算：空格分隔的 ISO（"2026-08-25 23:00:00+00:00"）
    # 没有 T 但同样是时刻，raw[:10] 会跳过换算、把这张纸看错一天
    if "T" in raw or "t" in raw or len(raw) > 10:
        return _anchor_date_of(raw)
    try:
        return date.fromisoformat(raw[:10]).isoformat()
    except ValueError:
        return None


async def _insert_note_change(conn, *, note: dict[str, Any], event: Optional[dict[str, Any]],
                              action: str, actor: str) -> None:
    """便签的变化记录。

    挂在日程上的走原来那条路（snapshot 就是事件本身 + comment），AI 侧眼前的显示一个字不变。
    贴在一整天上的没有事件可挂，用便签自己的 id 顶 event_id，snapshot 里打一个 unattached 标记 ——
    渲染那边多认一条分支就行，老那条完全不动
    """
    if event is not None:
        snapshot = dict(event)
        snapshot["comment"] = note
    else:
        snapshot = {
            "id": note["id"],
            "revision": 1,
            "unattached": True,
            "anchor_date": note["anchor_date"],
            "comment": note,
        }
    await _insert_change(
        conn, event=snapshot, action=action, actor=actor,
        source="manual", notify_master=(actor == "kitty"),
        notify_kitty=(actor == "master"),
    )


async def list_notes(
    storage,
    *,
    date_value: Optional[str] = None,
    from_value: Optional[str] = None,
    to_value: Optional[str] = None,
    limit: int = 500,
) -> list[dict[str, Any]]:
    """按天或按区间拉便签。区间是 [from, to)，跟事件那边一个规矩，前端月视图直接用"""
    await ensure_calendar_schema(storage)
    limit = max(1, min(int(limit or 500), 1000))
    where = ["deleted_at IS NULL"]
    args: list[Any] = []
    if date_value:
        d = _normalise_anchor(date_value)
        if not d:
            raise ValueError("invalid date")
        where.append("anchor_date = ?")
        args.append(d)
    else:
        if from_value:
            d = _normalise_anchor(from_value)
            if not d:
                raise ValueError("invalid from")
            where.append("anchor_date >= ?")
            args.append(d)
        if to_value:
            d = _normalise_anchor(to_value)
            if not d:
                raise ValueError("invalid to")
            where.append("anchor_date < ?")      # 开区间，月末那天不会被下个月重复拉一遍
            args.append(d)
    args.append(limit)
    rows = await _fetchall(
        storage._conn,
        "SELECT * FROM calendar_comments WHERE " + " AND ".join(where)
        + " ORDER BY anchor_date, created_at LIMIT ?",
        tuple(args),
    )
    return [_note_row(r) for r in rows]


async def get_note(storage, note_id: str) -> Optional[dict[str, Any]]:
    await ensure_calendar_schema(storage)
    row = await _fetchone(
        storage._conn, "SELECT * FROM calendar_comments WHERE id=?", (note_id,)
    )
    return _note_row(row) if row else None


async def update_note(
    storage,
    note_id: str,
    payload: dict[str, Any],
    *,
    actor: str,
) -> dict[str, Any]:
    """改一张便签：改字 / 挪位置 / 换绑的日程 / 点赞。只给要动的那几项。"""
    await ensure_calendar_schema(storage)
    note = await get_note(storage, note_id)
    if note is None or note.get("deleted_at"):
        raise ValueError("note not found")
    old_body = str(note.get("body") or "")

    sets: list[str] = []
    args: list[Any] = []
    liked_turned_on = False

    if "body" in payload:
        text = " ".join(str(payload.get("body") or "").split())[:2000]
        if not text:
            raise ValueError("comment is required")
        sets.append("body = ?"); args.append(text); note["body"] = text
    if "y" in payload:
        raw = payload.get("y")
        val = float(raw) if raw is not None else None
        sets.append("y = ?"); args.append(val); note["y"] = val
    if "event_id" in payload:
        eid = payload.get("event_id") or None
        if eid:
            ev = await get_event(storage, eid)
            if ev is None or ev.get("status") != "active":
                raise ValueError("event not found")
        sets.append("event_id = ?"); args.append(eid); note["event_id"] = eid
    if "anchor_date" in payload:
        d = _normalise_anchor(payload.get("anchor_date"))
        if not d:
            raise ValueError("invalid anchor_date")
        sets.append("anchor_date = ?"); args.append(d); note["anchor_date"] = d
    want_liked: Optional[bool] = None
    if "liked" in payload:
        want_liked = bool(payload.get("liked"))
        sets.append("liked = ?"); args.append(1 if want_liked else 0)
        note["liked"] = want_liked

    if not sets:
        return note

    now_iso = _iso(_now())
    sets.append("updated_at = ?"); args.append(now_iso); note["updated_at"] = now_iso
    args.append(note_id)

    event = await get_event(storage, note["event_id"]) if note.get("event_id") else None
    async with _LOCK:
        # 「刚被点上心」必须在锁里现查现判：外面那次 get_note 是锁外的脏读，
        # 两个 PATCH 同时进来会各自看到 liked=0，然后各推一条，那边连着看到两遍。
        # 读和写在同一把锁里才是原子的；这么写「取消之后再点一次」也照样通知
        liked_turned_on = False
        if want_liked:
            cur = await storage._conn.execute(
                "SELECT liked FROM calendar_comments WHERE id=?", (note_id,)
            )
            row = await cur.fetchone()
            liked_turned_on = row is not None and not bool(row[0])
        await storage._conn.execute(
            "UPDATE calendar_comments SET " + ", ".join(sets) + " WHERE id=?", tuple(args)
        )
        # 取消点赞不通知 —— 手滑点掉了不该再推一条
        if liked_turned_on:
            await _insert_note_change(
                storage._conn, note=note, event=event, action="like", actor=actor,
            )
        # 正文真的变了才记账（挪位置 / 换绑定不算 —— 用户拖来拖去是常态，不该扰人）。
        # 谁改了便签，对方那边就得亮。两个方向走同一条路
        if "body" in payload and str(note.get("body") or "") != old_body:
            await _insert_note_change(
                storage._conn, note=note, event=event, action="note_update", actor=actor,
            )
        await storage._conn.commit()
    return note


async def delete_note(storage, note_id: str, *, actor: str) -> dict[str, Any]:
    """撕掉一张便签。软删，行还在，只是 deleted_at 有值了。
    撕掉也记账 —— 对方撕了纸，这边得亮（哪个方向都一样）"""
    await ensure_calendar_schema(storage)
    note = await get_note(storage, note_id)
    if note is None or note.get("deleted_at"):
        raise ValueError("note not found")
    event = await get_event(storage, note["event_id"]) if note.get("event_id") else None
    now_iso = _iso(_now())
    note["deleted_at"] = now_iso
    note["updated_at"] = now_iso
    async with _LOCK:
        await storage._conn.execute(
            "UPDATE calendar_comments SET deleted_at=?, updated_at=? WHERE id=?",
            (now_iso, now_iso, note_id),
        )
        await _insert_note_change(
            storage._conn, note=note, event=event, action="note_delete", actor=actor,
        )
        await storage._conn.commit()
    return note


async def list_events(
    storage,
    *,
    date_value: Optional[str] = None,
    at: Optional[str] = None,
    from_value: Optional[str] = None,
    to_value: Optional[str] = None,
    new_only: bool = False,
    limit: int = 200,
) -> list[dict[str, Any]]:
    await ensure_calendar_schema(storage)
    clauses = ["e.status='active'"]
    params: list[Any] = []
    if date_value:
        local_day = date.fromisoformat(str(date_value))
        start = datetime.combine(local_day, time.min, tzinfo=_BJ).astimezone(timezone.utc)
        end = start + timedelta(days=1)
        clauses.append("e.starts_at < ? AND e.ends_at > ?")
        params.extend((_iso(end), _iso(start)))
    elif at:
        instant = _parse_datetime(at)
        clauses.append("e.starts_at <= ? AND e.ends_at > ?")
        params.extend((_iso(instant), _iso(instant)))
    elif from_value or to_value:
        start = _parse_datetime(from_value) if from_value else datetime(1970, 1, 1, tzinfo=timezone.utc)
        end = _parse_datetime(to_value) if to_value else datetime(9999, 1, 1, tzinfo=timezone.utc)
        clauses.append("e.starts_at < ? AND e.ends_at > ?")
        params.extend((_iso(end), _iso(start)))
    if new_only:
        clauses.append(
            "EXISTS (SELECT 1 FROM calendar_event_changes c "
            "JOIN calendar_change_receipts r ON r.change_id=c.id "
            "WHERE c.event_id=e.id AND r.consumer=? AND r.state='unseen')"
        )
        params.append(_CONSUMER)
    params.append(max(1, min(int(limit), 500)))
    rows = await _fetchall(
        storage._conn,
        "SELECT e.* FROM calendar_events e WHERE " + " AND ".join(clauses)
        + " ORDER BY e.starts_at,e.updated_at LIMIT ?",
        tuple(params),
    )
    return [_row_event(row) for row in rows]


async def _unseen_changes(storage) -> list[dict[str, Any]]:
    rows = await _fetchall(
        storage._conn,
        "SELECT c.* FROM calendar_event_changes c "
        "JOIN calendar_change_receipts r ON r.change_id=c.id "
        "WHERE r.consumer=? AND r.state='unseen' "
        "ORDER BY c.id DESC LIMIT 100",
        (_CONSUMER,),
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        item = dict(row)
        try:
            item["snapshot"] = json.loads(item["snapshot"])
        except (TypeError, json.JSONDecodeError):
            item["snapshot"] = {}
        out.append(item)
    return out


_MAX_SPAN_DAYS = 400   # 防跑飞：万一有人建一条十年长的事件，别一次算出三千多天


def _change_days(snapshot: Any) -> list[str]:
    """一条变化落在哪几天（产品时区自然日，"2026-08-25" 这种）。

    跨天的那几天全算 —— 一条 8/20-8/23 的出差，用户翻到 8/22 那一页确实是变了样的。
    算不出来就返回空列表，一条脏数据不许把整个接口带成 500
    """
    if not isinstance(snapshot, dict):
        return []
    # 贴在一整天上的便签，自己带 anchor_date
    if snapshot.get("unattached"):
        day = _normalise_anchor(snapshot.get("anchor_date"))
        return [day] if day else []
    # 挂在日程上的便签：用便签自己的 anchor，不是事件的跨度 —— 用户贴在哪一页就亮哪一页
    comment = snapshot.get("comment")
    if isinstance(comment, dict):
        day = _normalise_anchor(comment.get("anchor_date"))
        if day:
            return [day]
        # v2 迁移之前写的老记录 comment 里没有 anchor_date，回落到事件起始那天
        day = _anchor_date_of(snapshot.get("starts_at"))
        return [day] if day else []
    # 普通事件：整段跨度按产品时区半开区间展开，跟 list_events 的重叠判据一个语义。
    # 绝对不能截 starts_at 前十位 —— 生理期那条 UTC 是 08-24T16:00，截出来直接错一整天
    days = _expand_span_days(snapshot.get("starts_at"), snapshot.get("ends_at"))
    # 挪过日子的 update 快照带着改之前的跨度（prev_span）：原来那几天也变了样
    #（AI 侧挪走一条日程，原来那天必须亮感叹号）
    prev = snapshot.get("prev_span")
    if isinstance(prev, dict):
        for d in _expand_span_days(prev.get("starts_at"), prev.get("ends_at")):
            if d not in days:
                days.append(d)
    return days


def _expand_span_days(starts_raw: Any, ends_raw: Any) -> list[str]:
    try:
        start = _parse_datetime(starts_raw, assume_bj=False)
        end = _parse_datetime(ends_raw, assume_bj=False)
    except (TypeError, ValueError):
        return []
    cursor = start.astimezone(_BJ).date()
    last = end.astimezone(_BJ)
    days: list[str] = []
    while (datetime.combine(cursor, time.min, tzinfo=_BJ) < last
           and len(days) < _MAX_SPAN_DAYS):
        days.append(cursor.isoformat())
        cursor += timedelta(days=1)
    if not days:
        # ends_at <= starts_at 这种脏数据，至少把起始那天给出去
        days.append(start.astimezone(_BJ).date().isoformat())
    return days


async def _kitty_unseen_rows(conn) -> list[tuple[int, dict[str, Any]]]:
    """用户还没看的那些变化，一条一条配上解开的 snapshot。

    不加 LIMIT：未读会随着用户点日子不断被销掉，涨不起来；加了反而会静默漏掉日子。
    AI 侧那条线用的 _unseen_changes 有 LIMIT 100，那是它的事，别去动它
    """
    rows = await _fetchall(
        conn,
        "SELECT c.id AS change_id, c.snapshot AS snapshot FROM calendar_event_changes c "
        "JOIN calendar_change_receipts r ON r.change_id=c.id "
        "WHERE r.consumer=? AND r.state='unseen' ORDER BY c.id DESC",
        (_KITTY_CONSUMER,),
    )
    out: list[tuple[int, dict[str, Any]]] = []
    for row in rows:
        item = dict(row)
        try:
            snapshot = json.loads(item["snapshot"])
        except (TypeError, json.JSONDecodeError):
            snapshot = {}
        out.append((int(item["change_id"]), snapshot))
    return out


async def list_unseen_days(storage) -> list[str]:
    """AI 侧改过、用户还没点进去看的日子。前端那两个感叹号就画在这几天上"""
    await ensure_calendar_schema(storage)
    days: set[str] = set()
    for _change_id, snapshot in await _kitty_unseen_rows(storage._conn):
        days.update(_change_days(snapshot))
    return sorted(days)


async def mark_day_seen(storage, day: Any) -> int:
    """用户点进某一天 = 那一页看过了，压在这天上的未读收据全部销掉。

    按天筛在 SQL 层做不到（表里没有「天」这一列，日期埋在 snapshot 里、还是一对多），
    所以捞出来在 Python 里逐条对。跨天的那条整条销 —— 同一件事没必要报四遍。
    返回真正翻成 seen 的条数，同一天打第二遍就是 0，重复打不出错
    """
    await ensure_calendar_schema(storage)
    target = _normalise_anchor(day)
    if not target:
        raise ValueError("date is required")
    async with _LOCK:
        hits = [
            change_id
            for change_id, snapshot in await _kitty_unseen_rows(storage._conn)
            if target in _change_days(snapshot)
        ]
        if not hits:
            return 0
        placeholders = ",".join("?" for _ in hits)
        await storage._conn.execute(
            f"UPDATE calendar_change_receipts SET state='seen',seen_at=?,channel=? "
            f"WHERE consumer=? AND state='unseen' AND change_id IN ({placeholders})",
            (_iso(_now()), "kitty_app", _KITTY_CONSUMER, *hits),
        )
        await storage._conn.commit()
    return len(hits)


def _event_dt(event: dict[str, Any], key: str) -> datetime:
    return _parse_datetime(event.get(key), assume_bj=False)


# ------------------------------------------------------------
# 同日查重 —— 供需要避免重复的写入路径使用
#
# 手动路一律不查：REST 入口和 MCP 工具都不走这里。同一天想写三条一样的
# 是用户自己的自由，机器不该插嘴
# ------------------------------------------------------------


def _dup_title_key(value: Any) -> str:
    """查重用的标题归一：抹掉所有空白（str.split() 认全角空格），英文转小写"""
    return "".join(str(value or "").split()).lower()


def _dup_day_of(payload: dict[str, Any]) -> Optional[str]:
    """待写事件锚定的那一天（产品时区）。

    走 _normalise_times + _anchor_date_of 这条老路，绝不截 starts_at[:10] ——
    库里存的是 UTC，截字符串会把当地早八点前的事件算到前一天去。
    时间解不动就返回 None，这里不报错，留给 create_event 照原样抛
    """
    try:
        start, _end, _precision = _normalise_times(payload)
    except (TypeError, ValueError):
        return None
    return _anchor_date_of(_iso(start))


async def _dup_event_on_day(storage, payload: dict[str, Any]) -> Optional[dict[str, Any]]:
    """同一天里有没有标题重复的活事件（软删的不算，list_events 只出 status='active'）。

    判定：两个归一化标题互相包含就算重复；但短的那个长度必须 >= 2，
    否则「跑」「饭」这种单字标题会把一整天误伤掉。撞上返回那条事件，没撞返回 None
    """
    key = _dup_title_key(payload.get("title"))
    if len(key) < 2:
        return None
    day = _dup_day_of(payload)
    if not day:
        return None
    for existing in await list_events(storage, date_value=day, limit=500):
        other = _dup_title_key(existing.get("title"))
        if len(other) < 2:
            continue
        if key in other or other in key:
            return existing
    return None


async def complete_calendar_delivery(storage, delivery: Optional[CalendarDelivery]) -> None:
    """把一批 [NEW] 回执标成 seen —— execute_calendar_tool 的 list 动作靠它把感叹号熄掉。

    conversation_id / now_signature 那半在开源版里闲置（没有对话注入这条路），
    无害地留着：签名协议属于数据层，砍了反而跟生产版分叉
    """
    if delivery is None:
        return
    await ensure_calendar_schema(storage)
    async with _LOCK:
        if delivery.change_ids:
            placeholders = ",".join("?" for _ in delivery.change_ids)
            await storage._conn.execute(
                f"UPDATE calendar_change_receipts SET state='seen',seen_at=?,channel=? "
                f"WHERE consumer=? AND change_id IN ({placeholders})",
                (
                    _iso(_now()), delivery.channel, _CONSUMER,
                    *delivery.change_ids,
                ),
            )
        if delivery.conversation_id is not None and delivery.now_signature is not None:
            await storage._conn.execute(
                "INSERT INTO calendar_consumer_state("
                "consumer,conversation_id,last_now_signature,updated_at"
                ") VALUES(?,?,?,?) "
                "ON CONFLICT(consumer,conversation_id) DO UPDATE SET "
                "last_now_signature=excluded.last_now_signature,"
                "updated_at=excluded.updated_at",
                (
                    _CONSUMER, delivery.conversation_id,
                    delivery.now_signature, _iso(_now()),
                ),
            )
        await storage._conn.commit()


# ============================================================
# 环境块 —— 「此刻日历上有什么」，一段可以直接塞进上下文的文字
#
# 这是给「有自己聊天管道」的人用的那一路：每轮对话组装上下文的时候取一次，
# 贴进 system prompt 或者环境注入块，AI 就知道现在几点该干什么。
#
#   <calendar>
#   [NEW]
#   [NEW][NOW] 17:00–18:00 看牙医（用户新增）
#
#   [TODAY]
#   09:30 组会
#   </calendar>
#
# 三段的意思：
#   [NEW]   —— 用户改过、AI 还没看过的（读完可以标记熄灭）
#   [NOW]   —— 此刻正在进行的（整天事件不算，那种没有「正在」可言）
#   [TODAY] —— 今天其余的
# 一条事件只出现在最靠前的那一段里，不重复。三段都空就返回空字符串，
# 什么都没有的时候不要往上下文里塞一个空壳
# ============================================================


def _is_now(event: dict[str, Any], now: datetime) -> bool:
    """此刻正在进行。整天事件不算 —— 「全天」没有「正在」可言"""
    return (
        event.get("status") == "active"
        and event.get("precision") != "day"
        and _event_dt(event, "starts_at") <= now < _event_dt(event, "ends_at")
    )


def _is_today(event: dict[str, Any], now: datetime) -> bool:
    local = now.astimezone(_BJ)
    day_start = datetime.combine(local.date(), time.min, tzinfo=_BJ).astimezone(timezone.utc)
    day_end = day_start + timedelta(days=1)
    return (
        event.get("status") == "active"
        and _event_dt(event, "starts_at") < day_end
        and _event_dt(event, "ends_at") > day_start
    )


def _span(event: dict[str, Any], now: Optional[datetime] = None) -> str:
    """时间那一段。今天之内只报时刻，跨天的才带上月日 —— 省字，也更好读"""
    start = _event_dt(event, "starts_at").astimezone(_BJ)
    end = _event_dt(event, "ends_at").astimezone(_BJ)
    if event.get("precision") == "day":
        return f"{start:%m-%d} 全天"
    reference = (now or _now()).astimezone(_BJ).date()
    if start.date() == end.date() and start.date() == reference:
        return f"{start:%H:%M}–{end:%H:%M}"
    if start.date() == end.date():
        return f"{start:%m-%d %H:%M}–{end:%H:%M}"
    return f"{start:%m-%d %H:%M}–{end:%m-%d %H:%M}"


def _event_line(event: dict[str, Any], *, tags: str = "",
                now: Optional[datetime] = None) -> str:
    prefix = f"{tags} " if tags else ""
    return f"{prefix}{_span(event, now)} {event.get('title') or '(未命名)'}"


def _unattached_note_line(event: dict[str, Any], change: dict[str, Any],
                          now: datetime) -> str:
    """贴在一整天上、不挂任何日程的便签。

    _event_line 靠事件的起止时刻排版，这种便签压根没有事件可挂，所以单独走这一条
    """
    note = event.get("comment") or {}
    anchor = str(event.get("anchor_date") or "")
    tags = ["NEW"]
    if anchor and anchor == now.astimezone(_BJ).date().isoformat():
        tags.append("TODAY")
    head = "".join(f"[{tag}]" for tag in tags)
    when = anchor[5:] if len(anchor) >= 10 else anchor      # "08-03"
    body = str(note.get("body") or "")
    who = config.USER_NAME
    action = str(change.get("action"))
    if action == "like":
        return f"{head} {when} {who}给你点了心：「{body}」"
    if action == "note_update":
        return f"{head} {when} {who}改了便签：{body}"
    if action == "note_delete":
        return f"{head} {when} {who}撕掉了便签：「{body}」"
    return f"{head} {when} {who}留言：{body}"


def _change_line(change: dict[str, Any], now: datetime) -> str:
    event = change.get("snapshot") or {}
    if event.get("unattached"):
        return _unattached_note_line(event, change, now)
    who = config.USER_NAME
    tags = ["NEW"]
    if _is_now(event, now):
        tags.append("NOW")
    elif _is_today(event, now):
        tags.append("TODAY")
    action = {
        "create": f"{who}新增",
        "update": f"{who}修改",
        "delete": f"{who}删除",
        "comment": f"{who}留言",
        "like": f"{who}点赞",
        "note_update": f"{who}改了便签",
        "note_delete": f"{who}撕了便签",
    }.get(str(change.get("action")), f"{who}更新")
    line = _event_line(event, tags="".join(f"[{tag}]" for tag in tags), now=now)
    if change.get("action") in ("comment", "like", "note_update", "note_delete"):
        body = str(((event.get("comment") or {}).get("body")) or "")
        return f"{line}（{action}：{body}）"
    return f"{line}（{action}）"


async def _events_for_view(storage, now: datetime) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    local = now.astimezone(_BJ)
    today = await list_events(storage, date_value=local.date().isoformat())
    active = [event for event in today if _is_now(event, now)]
    return active, today


async def render_env_block(storage, *, now: Optional[datetime] = None,
                           include_new: bool = True) -> CalendarDelivery:
    """「此刻日历上有什么」，渲染成一段可以直接注入上下文的文字。

    include_new=False 就只出 [NOW] 和 [TODAY] —— 适合每轮都补一遍当前状态、
    但不想反复报同一批「新变化」的场合。

    返回里的 change_ids 是这次报出去的那批 [NEW]；调用方把文字成功用上之后，
    拿这批 id 调 complete_calendar_delivery 就能让它们熄灭。分两步是有意的：
    注入失败的时候不该把「用户改了什么」这件事白白销掉
    """
    await ensure_calendar_schema(storage)
    current = (now or _now()).astimezone(timezone.utc)
    changes = await _unseen_changes(storage) if include_new else []
    active, today = await _events_for_view(storage, current)

    sections: list[str] = []
    seen_event_ids = {str(item.get("event_id")) for item in changes}
    if changes:
        sections.append("[NEW]\n" + "\n".join(_change_line(item, current) for item in changes))
    # 已经在 [NEW] 里报过的不再重复出现在 [NOW] / [TODAY]
    now_rows = [e for e in active if str(e.get("id")) not in seen_event_ids]
    if now_rows:
        sections.append("[NOW]\n" + "\n".join(_event_line(e, now=current) for e in now_rows))
    used = seen_event_ids | {str(e.get("id")) for e in now_rows}
    today_rows = [e for e in today if str(e.get("id")) not in used]
    if today_rows:
        sections.append("[TODAY]\n" + "\n".join(_event_line(e, now=current) for e in today_rows))

    text = "<calendar>\n" + "\n\n".join(sections) + "\n</calendar>" if sections else ""
    return CalendarDelivery(
        text=text,
        change_ids=tuple(int(item["id"]) for item in changes),
        channel="env",
    )


# ============================================================
# see —— AI 侧看用户的那一页
#
# 图是用户手机渲染上传的（routes.py 的 /pages 端点，一天一张覆盖写），
# 文字从数据库直出：事件、便签、原文。那一页只有用户能画，
# 所以图就等于用户最后一次看到的样子；图之后 AI 侧自己动过的，文字里补一句就够
# ============================================================

_PAGES_DIR = Path(config.PAGES_DIR)


@dataclass
class CalendarSeeResult:
    """text + 那一页的 PNG。as_mcp_content 给 MCP 那条路出 text/image 内容块"""

    text: str
    image_path: Optional[str] = None

    @property
    def log_text(self) -> str:
        return self.text

    def image_bytes(self) -> Optional[bytes]:
        if not self.image_path:
            return None
        path = Path(self.image_path)
        return path.read_bytes() if path.is_file() else None

    def as_mcp_content(self) -> list[dict[str, Any]]:
        blocks: list[dict[str, Any]] = [{"type": "text", "text": self.text}]
        data = self.image_bytes()
        if data:
            blocks.append({
                "type": "image",
                "data": base64.b64encode(data).decode("ascii"),
                "mimeType": "image/png",
            })
        return blocks


def _who(actor: Optional[str]) -> str:
    """协议里的 kitty / master 换成人话再给 AI 看。
    读这段文字的就是 AI 自己，所以 master 一律说「你」；
    kitty 那侧用 CALENDAR_USER_NAME 配的名字（没填就是占位符 USER）"""
    a = (actor or "").lower()
    if a in ("master", "assistant"):
        return "你"
    if a == "kitty":
        return config.USER_NAME
    return actor or "?"


def _see_event_line(event: dict[str, Any]) -> str:
    """一行一条：时间 标题 · 作者，特殊类型缀在尾巴上。
    整日事件的最后一天 = ends_at 前一天（ends_at 是开区间的次日零点）"""
    start = _event_dt(event, "starts_at").astimezone(_BJ)
    end = _event_dt(event, "ends_at").astimezone(_BJ)
    if event.get("precision") == "day":
        last = (end - timedelta(minutes=1)).date()
        when = (f"{start:%m-%d} 全天" if last <= start.date()
                else f"{start:%m-%d}–{last:%m-%d} 全天")
    elif start.date() == end.date():
        when = f"{start:%H:%M}–{end:%H:%M}"
    else:
        when = f"{start:%m-%d %H:%M}–{end:%m-%d %H:%M}"
    line = f"{when} {event.get('title') or '(未命名)'} · {_who(event.get('created_by'))}"
    if event.get("event_type"):
        line += f" ({event['event_type']})"
    return line


def _see_note_line(note: dict[str, Any], events_by_id: dict[str, str]) -> str:
    when = ""
    try:
        when = (_parse_datetime(note.get("created_at"), assume_bj=False)
                .astimezone(_BJ).strftime("%m-%d %H:%M"))
    except (TypeError, ValueError):
        pass
    line = f"{_who(note.get('author'))} {when}: {note.get('body') or ''}".strip()
    linked = str(note.get("event_id") or "")
    if linked and linked in events_by_id:
        line += f"（贴在「{events_by_id[linked]}」上）"
    if note.get("liked"):
        line += " ♥"
    return line


async def _master_changes_since(storage, day: str, cutoff: datetime) -> list[str]:
    """页面图之后 AI 侧又动了什么。图不会重画（只有手机端会画），文字里补一句"""
    # LIMIT 必须在按天过滤之后才有意义 —— 在 SQL 层就截 40 条的话，图很旧、期间
    # master 全表改动多于 40 条时，真正属于这一天的会被静默挤掉。cutoff 之后的量级
    # 本来就小，SQL 层只留一个防跑飞的大顶，展示截断在函数末尾做
    rows = await _fetchall(
        storage._conn,
        "SELECT action, snapshot, created_at FROM calendar_event_changes "
        "WHERE actor='master' AND created_at > ? ORDER BY id LIMIT 500",
        (_iso(cutoff),),
    )
    lines: list[str] = []
    for row in rows:
        item = dict(row)
        try:
            snapshot = json.loads(item["snapshot"])
        except (TypeError, json.JSONDecodeError):
            continue
        if day not in _change_days(snapshot):
            continue
        action = {"create": "加了", "update": "改了", "delete": "删了",
                  "comment": "留了便签", "like": "点了赞",
                  "note_update": "改了便签", "note_delete": "撕了便签"}.get(
                      str(item.get("action")), "动了")
        title = str(snapshot.get("title") or "")
        comment = snapshot.get("comment")
        if isinstance(comment, dict) and str(item.get("action")) in (
                "comment", "like", "note_update", "note_delete"):
            body = str(comment.get("body") or "")
            title = f"「{body}」" if body else title
        when = ""
        try:
            when = (_parse_datetime(item.get("created_at"), assume_bj=False)
                    .astimezone(_BJ).strftime("%H:%M"))
        except (TypeError, ValueError):
            pass
        lines.append(f"{when} {action} {title}".strip())
    if len(lines) > 8:
        lines = lines[:8] + [f"…还有 {len(lines) - 8} 处"]
    return lines


async def execute_calendar_see(storage, arguments: dict[str, Any]) -> CalendarSeeResult:
    await ensure_calendar_schema(storage)
    raw_date = arguments.get("date")
    if raw_date:
        day = _normalise_anchor(raw_date)
        if not day:
            return CalendarSeeResult(text=_json({"ok": False, "error": "invalid date"}))
    else:
        day = _now().astimezone(_BJ).date().isoformat()

    events = await list_events(storage, date_value=day)
    notes = await list_notes(storage, date_value=day)
    weekday = "一二三四五六日"[date.fromisoformat(day).weekday()]
    lines = [f"{day} 周{weekday} · {config.USER_NAME}日历的这一页"]

    page = _PAGES_DIR / f"{day}.png"
    image_path: Optional[str] = None
    try:
        if page.is_file():
            image_path = str(page)
            mtime = datetime.fromtimestamp(page.stat().st_mtime, tz=timezone.utc)
            stamp = mtime.astimezone(_BJ)
            today_bj = _now().astimezone(_BJ).date()
            stamp_s = (stamp.strftime("%H:%M") if stamp.date() == today_bj
                       else stamp.strftime("%m-%d %H:%M"))
            lines.append(f"页面图：{config.USER_NAME}手机 {stamp_s} 渲染的，随文附上")
            later = await _master_changes_since(storage, day, mtime)
            if later:
                lines.append("图之后你又动过（图上看不到）：" + "；".join(later))
        else:
            lines.append(f"页面图：这一天{config.USER_NAME}还没画过或还没传上来，只有下面的文字")
    except OSError:
        # is_file 和 stat 之间文件被人删了这种极端情形：降级成纯文字，别把整条流带崩
        # （image_bytes 里自有 is_file 兜底，读不到就只出文字块）
        image_path = None
        lines.append("页面图：读取失败，这次只有文字")

    if events:
        lines.append("[事件]")
        lines.extend(_see_event_line(e) for e in events)
    if notes:
        events_by_id = {str(e.get("id")): str(e.get("title") or "") for e in events}
        lines.append("[便签]")
        lines.extend(_see_note_line(n, events_by_id) for n in notes)
    if not events and not notes:
        lines.append("这一天数据库里空着：没有日程也没有便签")
    return CalendarSeeResult(text="\n".join(lines), image_path=image_path)


async def execute_calendar_tool(
    storage,
    arguments: dict[str, Any],
    *,
    conversation_id: Optional[str] = None,
) -> Any:
    """大多数动作返回 JSON 字符串；see 返回 CalendarSeeResult（带图）。
    MCP 那边靠 hasattr(as_mcp_content) 认。"""
    action = str(arguments.get("action") or "list").strip().lower()
    try:
        if action in ("see", "get"):
            # get 并进 see（都是「看」，不该占两个动作）。
            # 带 event_id = 看那一条的详情（原 get，纯数据）；
            # 不带 = 看某一天的整页（图 + 文字，date 默认今天）。
            # "get" 不再写进 schema，但发过来照样认 —— 别的窗口的旧习惯不能炸
            if arguments.get("event_id"):
                event = await get_event(storage, str(arguments.get("event_id") or ""))
                return _json({"ok": event is not None, "event": event})
            return await execute_calendar_see(storage, arguments)
        if action == "list":
            events = await list_events(
                storage,
                date_value=arguments.get("date"),
                at=arguments.get("at"),
                from_value=arguments.get("from"),
                to_value=arguments.get("to"),
                new_only=bool(arguments.get("new_only", False)),
                limit=int(arguments.get("limit") or 200),
            )
            changes = await _unseen_changes(storage)
            result = {
                "ok": True,
                "events": events,
                "new_changes": changes,
                "count": len(events),
            }
            if changes:
                await complete_calendar_delivery(
                    storage,
                    CalendarDelivery(
                        change_ids=tuple(int(item["id"]) for item in changes),
                        channel="calendar_tool",
                    ),
                )
            return _json(result)
        if action == "create":
            event = await create_event(storage, arguments, actor="master", source="manual")
            return _json({"ok": True, "event": event})
        if action in ("update", "like"):
            # update 就是「改」，事件和便签都归它 ——
            # 带 note_id 改便签（改字 / 点心 / 收心），带 event_id 改事件。
            # "like" 从菜单撤了但发过来照样认（liked 默认 true 的便签 update）
            note_id = str(arguments.get("note_id") or arguments.get("comment_id") or "")
            if note_id:
                patch: dict[str, Any] = {}
                if action == "like" or "liked" in arguments:
                    patch["liked"] = bool(arguments.get("liked", True))
                body = str(arguments.get("comment") or arguments.get("body") or "")
                if body:
                    patch["body"] = body
                note = await update_note(storage, note_id, patch, actor="master")
                return _json({"ok": True, "comment": note})
            event = await update_event(
                storage, str(arguments.get("event_id") or ""),
                arguments, actor="master", source="manual",
            )
            return _json({"ok": True, "event": event})
        if action == "delete":
            # 同一个道理：带 note_id 撕便签，带 event_id 删事件
            note_id = str(arguments.get("note_id") or arguments.get("comment_id") or "")
            if note_id:
                note = await delete_note(storage, note_id, actor="master")
                return _json({"ok": True, "comment": note})
            event = await delete_event(
                storage, str(arguments.get("event_id") or ""),
                actor="master", source="manual",
            )
            return _json({"ok": True, "event": event})
        if action == "comment":
            # 给了 event_id 就是挂在那条日程上（老行为，一个字没变）；
            # 只给 date 就是贴在那一整天的纸面上，跟手机端撕一张空白便签是同一件事
            comment = await add_note(
                storage,
                body=str(arguments.get("comment") or ""),
                author="master",
                event_id=str(arguments.get("event_id") or "") or None,
                anchor_date=arguments.get("date"),
            )
            return _json({"ok": True, "comment": comment})
        return _json({"ok": False, "error": f"unknown action: {action}"})
    except (TypeError, ValueError) as exc:
        return _json({"ok": False, "error": str(exc)})
