"""可选模块：把每年都过的日子铺进日历。

生日、纪念日、节日这些不用谁去记，写一次就该年年都在。这个模块干的就是这件事：
你给一张「几月几号 + 叫什么」的表，它往后铺几年，每年一条。

## 怎么用

在服务旁边放一个 JSON 文件，路径由 CALENDAR_SEED_FILE 指定（不配就整个模块不启用）：

    [
      {"month_day": "03-15", "type": "birthday",    "title": "生日"},
      {"month_day": "06-01", "type": "anniversary", "title": "纪念日"},
      {"month_day": "12-25", "type": "holiday",     "title": "圣诞"}
    ]

服务每次启动时铺一遍，默认铺今年和明年（CALENDAR_SEED_YEARS 可以改）。
重复启动不会写重 —— 每条的 id 是「月日 + 类型 + 年份」算出来的，同一条永远同一个 id。

## 为什么这些日子要单独有个模块

它们跟临时安排不一样：不是某天要做什么，而是某天本身有意义。日历上会盖章
（前端对 birthday / anniversary 这两种类型有专门的画法），而且提前很久就该看得见。

## 农历怎么办

这个模块只认公历。农历生日、春节中秋这些，每年的公历日期都不一样，
自己在表里补当年的具体日期就行（type 照样写 holiday）。
"""

from __future__ import annotations

import hashlib
import json
import logging
from pathlib import Path
from typing import Any

import config
from calendar_core import _BJ, _now, create_event

logger = logging.getLogger(__name__)


def _stable_id(month_day: str, kind: str, year: int) -> str:
    """同一条 = 同一个 id，所以重复启动只会命中已有的那条，不会写重"""
    digest = hashlib.sha256(f"{month_day}:{kind}:{year}".encode("utf-8")).hexdigest()
    return f"cal_seed_{digest[:16]}"


def _load_seeds() -> list[dict[str, Any]]:
    if not config.SEED_FILE:
        return []
    path = Path(config.SEED_FILE)
    if not path.is_file():
        logger.warning("seeder: %s 不存在，跳过", path)
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        # 种子文件写错了不该把服务带崩，说清楚哪里错了然后跳过就行
        logger.warning("seeder: %s 读不动或不是合法 JSON（%s），跳过", path, exc)
        return []
    if not isinstance(data, list):
        logger.warning("seeder: %s 顶层应该是个数组，跳过", path)
        return []
    return [item for item in data if isinstance(item, dict)]


async def seed(storage) -> dict[str, int]:
    """铺一遍。返回新写了几条、已经在了几条。

    整天事件：starts_at 只给日期，create_event 会按产品时区补成那天零点，
    ends_at 自动是次日零点（开区间）。这里绝不自己拼时间字符串
    """
    seeds = _load_seeds()
    counts = {"created": 0, "existing": 0, "skipped": 0}
    if not seeds:
        return counts

    this_year = _now().astimezone(_BJ).year
    for item in seeds:
        month_day = str(item.get("month_day") or "").strip()
        # 只认 MM-DD。写错了跳过，不猜
        if len(month_day) != 5 or month_day[2] != "-":
            logger.warning("seeder: month_day 应该是 MM-DD，跳过 %r", item)
            counts["skipped"] += 1
            continue
        kind = str(item.get("type") or "recurring").strip() or "recurring"
        title = str(item.get("title") or item.get("note") or kind).strip()
        if not title:
            counts["skipped"] += 1
            continue

        for year in range(this_year, this_year + config.SEED_YEARS):
            day = f"{year}-{month_day}"
            metadata = {"seed": month_day}
            rail = item.get("rail")
            if isinstance(rail, bool):
                metadata["rail"] = rail
            payload = {
                "title": title,
                "starts_at": day,
                "precision": "day",
                "event_type": kind,
                "metadata": metadata,
            }
            try:
                event = await create_event(
                    storage, payload,
                    actor="kitty", source="seed",
                    event_id=_stable_id(month_day, kind, year),
                )
            except (TypeError, ValueError) as exc:
                # 2 月 30 号这种写错的日期会在这里被挡下
                logger.warning("seeder: %s 写不进去：%s", day, exc)
                counts["skipped"] += 1
                continue
            if event.get("created"):
                counts["created"] += 1
            else:
                counts["existing"] += 1

    logger.info("seeder: 新写 %s 条，已在 %s 条，跳过 %s 条",
                counts["created"], counts["existing"], counts["skipped"])
    return counts
