"""Fill a throwaway demo database with USER / ASSISTANT sample pages.

Run from server/ with CALENDAR_DB pointing at an isolated file.
Do not point CALENDAR_DB at a calendar you already use.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path

import calendar_core as cal
import config

STICKERS = {
    "cat": "5713CA70-0000-4000-A000-000000000001",
    "camera": "5713CA70-0000-4000-A000-000000000002",
    "cup": "5713CA70-0000-4000-A000-000000000003",
    "ticket": "5713CA70-0000-4000-A000-000000000004",
    "heart": "5713CA70-0000-4000-A000-000000000005",
}


def placed_path(date: str) -> Path:
    return Path(config.CALENDAR_DB).expanduser().resolve().parent / "placed" / f"{date}.json"


def write_placed(date: str, items: list[dict]) -> None:
    path = placed_path(date)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"date": date, "items": items}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


async def main() -> None:
    storage = cal.Storage(config.CALENDAR_DB)
    await storage.connect()
    try:
        await cal.create_event(
            storage,
            {
                "title": "看电影",
                "starts_at": "2026-08-03T20:00:00+08:00",
                "ends_at": "2026-08-03T22:30:00+08:00",
                "precision": "minute",
            },
            actor="master",
            source="manual",
        )
        await cal.add_note(
            storage, body="查了下，评价不错", author="master",
            anchor_date="2026-08-03", y=180,
        )
        await cal.add_note(
            storage, body="那就看这部", author="kitty",
            anchor_date="2026-08-03", y=250,
        )

        await cal.create_event(
            storage,
            {
                "title": "做蛋糕",
                "starts_at": "2026-08-08",
                "precision": "day",
            },
            actor="kitty",
            source="manual",
        )
        await cal.add_note(
            storage, body="想吃芋泥的那个", author="kitty",
            anchor_date="2026-08-08", y=220,
        )

        await cal.create_event(
            storage,
            {
                "title": "出差",
                "starts_at": "2026-08-12",
                "ends_at": "2026-08-15",
                "precision": "day",
            },
            actor="master",
            source="manual",
        )

        await cal.create_event(
            storage,
            {
                "title": "剪头发",
                "starts_at": "2026-08-17T15:00:00+08:00",
                "ends_at": "2026-08-17T16:00:00+08:00",
                "precision": "minute",
            },
            actor="kitty",
            source="manual",
        )
        await cal.create_event(
            storage,
            {
                "title": "陪你练答辩",
                "starts_at": "2026-08-17T18:30:00+08:00",
                "ends_at": "2026-08-17T20:30:00+08:00",
                "precision": "minute",
            },
            actor="master",
            source="manual",
        )
        n1 = await cal.add_note(
            storage, body="答辩稿卡住了", author="kitty",
            anchor_date="2026-08-17", y=210,
        )
        await cal.add_note(
            storage, body="发我，我帮你捋", author="master",
            anchor_date="2026-08-17", y=300,
        )
        n3 = await cal.add_note(
            storage, body="捋完了，好多了", author="kitty",
            anchor_date="2026-08-17", y=390,
        )
        await cal.update_note(storage, n3["id"], {"liked": True}, actor="kitty")

        write_placed("2026-08-17", [
            {
                "id": str(uuid.uuid4()),
                "kind": "sticker",
                "stickerID": STICKERS["cat"],
                "x": 48, "y": 520, "scale": 1, "rotation": -6,
            },
            {
                "id": str(uuid.uuid4()),
                "kind": "sticker",
                "stickerID": STICKERS["cup"],
                "x": 250, "y": 640, "scale": 1, "rotation": 4,
            },
            {
                "id": str(uuid.uuid4()),
                "kind": "sticker",
                "stickerID": STICKERS["heart"],
                "x": 300, "y": 280, "scale": 0.9, "rotation": 8,
            },
        ])

        await cal.create_event(
            storage,
            {
                "title": "纪念日",
                "starts_at": "2026-08-25",
                "precision": "day",
                "event_type": "anniversary",
            },
            actor="master",
            source="manual",
        )
        await cal.add_note(
            storage, body="别让我忘了", author="kitty",
            anchor_date="2026-08-25", y=240,
        )

        await cal.create_event(
            storage,
            {
                "title": "图书馆",
                "starts_at": "2026-08-26T13:00:00+08:00",
                "ends_at": "2026-08-26T17:00:00+08:00",
                "precision": "minute",
            },
            actor="kitty",
            source="manual",
        )
        await cal.add_note(
            storage, body="今天把网页跑通了", author="master",
            anchor_date="2026-08-26", y=220,
        )
        await cal.add_note(
            storage, body="那明天继续贴贴纸", author="kitty",
            anchor_date="2026-08-26", y=310,
        )
        write_placed("2026-08-26", [
            {
                "id": str(uuid.uuid4()),
                "kind": "sticker",
                "stickerID": STICKERS["ticket"],
                "x": 40, "y": 480, "scale": 1, "rotation": -8,
            },
            {
                "id": str(uuid.uuid4()),
                "kind": "sticker",
                "stickerID": STICKERS["camera"],
                "x": 260, "y": 560, "scale": 1, "rotation": 3,
            },
        ])
        print("demo seed ok")
        print(f"notes touched: {n1['id'][:8]}…")
    finally:
        await storage.close()


if __name__ == "__main__":
    asyncio.run(main())
