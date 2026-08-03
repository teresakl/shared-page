"""可选模块：从一句话里把「未来的安排」抽出来，自动写进日历。

这是这个项目的第三种笔迹（AUTO）的生产者。前两种是人写的和 AI 写的，
这一种没有人动手 —— 你把聊天里的每句话喂给它，它自己判断有没有值得记的安排。

    你："下周三答辩" → 日历上多一条 8/12 答辩，灰色的，谁都没动手

## 怎么开

四个环境变量，缺任何一个整个模块就是关的（服务照常跑，只是不会自动记事）：

    EXTRACTOR_BASE_URL   任何 OpenAI 兼容的接口，比如 https://api.deepseek.com
    EXTRACTOR_API_KEY    你自己的 key
    EXTRACTOR_MODEL      模型名，比如 deepseek-chat
    （可选）EXTRACTOR_MIN_CONFIDENCE  默认 0.6

## 怎么接

它不自己去读你的聊天记录 —— 你的聊天在哪、长什么样，它不知道，也不该知道。
你在自己的聊天管道里，每收到一条用户消息，往这儿 POST 一次就行：

    POST /api/v1/calendar/extract
    {"text": "下周三答辩", "now": "2026-08-03T20:00:00+08:00"}

`now` 可以不给，不给就用服务器当前时间。返回里有抽到了什么、写进去了几条、
哪些因为置信度不够或者跟已有的事件重复被跳过了。

## 为什么要有置信度这道门

模型对「下周三答辩」很确定（0.9），对「这周末想去逛街」就没那么确定（0.6），
对「改天一起吃饭吧」压根不给候选。低于门槛的直接丢掉，宁可漏记也别乱记 ——
日历是每天要看的东西，里面多一条假的比少一条真的更烦人。
门槛想调松就把 EXTRACTOR_MIN_CONFIDENCE 调低，0.5 会更爱记，0.8 会很矜持。
"""

from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any, Optional

import config
from calendar_core import (_BJ, _dup_day_of, _dup_event_on_day, _now,
                           create_event)

logger = logging.getLogger(__name__)

# 一次消息最多认几条安排。说一句话同时安排五件事的情况极少，
# 上限主要是防模型跑飞了往日历里灌一串
_MAX_CANDIDATES = 3

SYSTEM_PROMPT = """你是日程抽取器,为一个人和 ta 的 AI 伴侣共用的日历服务。输入是用户发出的单条消息和今天的日期。只判断这一条消息字面携带的安排,不猜上下文:
- 必须是未来的事,已经发生的、正在发生的都不算
- 必须能落到具体的某一天:明确日期,或者「明天」「下周三」「16号」这类能从今天推算出来的说法
- 没有具体日子的愿望不算(「改天一起吃饭」「以后想去旅行」)
- 规律性的事实不算,那不是某一次(「每周三都有组会」)
- 别人的安排不算(「我妈说下周来看我」)
- 还没定的条件句不算(「如果不下雨就去爬山」)
时间怎么填:说了几点就填几点,precision 用 "hour";只说了上午/下午/晚上,起点填那个时段的开头(9:00/14:00/19:00),precision 用 "segment";只说了哪天没说时刻,起点填那天零点、ends_at 填次日零点,precision 用 "day"。ends_at 是开区间——一件事「到 16 号」,ends_at 要写 17 号。一律用带时区偏移的 ISO 格式。
confidence:日期和时刻都明确给 0.9 以上;日期明确、只是没说几点给 0.7 左右(这仍然是一条好安排,别因为没报钟点就压很低);日子本身要靠推算(「这周末」「过两天」)给 0.6 左右。
无安排输出空数组。日期基于今天推算。严格只输出一个 JSON 对象:
{"candidates":[{"title":"这件事本身,简短","starts_at":"ISO+时区","ends_at":"ISO+时区","precision":"minute|hour|segment|day","confidence":0.0}]}"""


def enabled() -> bool:
    """三样都配齐了才算开。缺一样这个模块整个不存在"""
    return bool(config.EXTRACTOR_BASE_URL and config.EXTRACTOR_API_KEY
                and config.EXTRACTOR_MODEL)


def _user_content(text: str, now: datetime) -> str:
    """喂给模型的东西只有两样：当前时间（不然它算不出「下周三」是几号）和这句话。

    不送上下文 —— 一句话能不能看出安排，就看这一句。送历史会让它把
    早就聊过的旧安排重复提取出来
    """
    return (f"【当前时间】\n{now.astimezone(_BJ).isoformat(timespec='minutes')}\n\n"
            f"【这句话】\n{text[:4000]}")


async def _ask_model(text: str, now: datetime) -> list[dict[str, Any]]:
    """调一次模型，把 candidates 拿回来。任何失败都返回空 —— 抽取失败不该影响别的事"""
    import httpx

    body = {
        "model": config.EXTRACTOR_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": _user_content(text, now)},
        ],
        "temperature": 0,
        "max_tokens": 800,
        "response_format": {"type": "json_object"},
    }
    url = config.EXTRACTOR_BASE_URL.rstrip("/") + "/chat/completions"
    headers = {"Authorization": f"Bearer {config.EXTRACTOR_API_KEY}"}
    try:
        async with httpx.AsyncClient(timeout=config.EXTRACTOR_TIMEOUT) as cli:
            resp = await cli.post(url, json=body, headers=headers)
            resp.raise_for_status()
            raw = resp.json()["choices"][0]["message"]["content"]
    except Exception:
        logger.warning("extractor: model call failed", exc_info=True)
        return []
    # 有些模型会在 JSON 外面裹一层 ```json 围栏
    raw = str(raw or "").strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0]
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        logger.warning("extractor: model returned non-JSON: %s", raw[:200])
        return []
    items = data.get("candidates") if isinstance(data, dict) else None
    return [c for c in (items or []) if isinstance(c, dict)]


async def extract_and_apply(storage, text: str, *,
                            now: Optional[datetime] = None,
                            source_message_id: Optional[str] = None,
                            ) -> dict[str, Any]:
    """一句话进来，抽出安排、过门槛、查重、写库。

    返回里把每条候选的去向都写清楚（写了 / 置信度不够 / 跟哪条重了），
    调用方能直接拿去看这一路到底在干什么 —— 这条链路最怕的就是无声失败
    """
    if not enabled():
        return {"ok": False, "error": "extractor is not configured", "applied": [], "skipped": []}

    text = " ".join(str(text or "").split())
    if len(text) < config.EXTRACTOR_MIN_CHARS:
        return {"ok": True, "applied": [], "skipped": [], "reason": "text too short"}

    moment = now or _now()
    candidates = (await _ask_model(text, moment))[:_MAX_CANDIDATES]

    applied: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []

    for raw in candidates:
        title = str(raw.get("title") or "").strip()
        try:
            confidence = float(raw.get("confidence") or 0.0)
        except (TypeError, ValueError):
            confidence = 0.0

        if not title or not raw.get("starts_at"):
            skipped.append({"title": title, "why": "missing title or start time"})
            continue
        if confidence < config.EXTRACTOR_MIN_CONFIDENCE:
            skipped.append({"title": title, "confidence": confidence,
                            "why": f"below threshold {config.EXTRACTOR_MIN_CONFIDENCE}"})
            logger.info("extractor: dropped %r (confidence %.2f)", title, confidence)
            continue

        dup = await _dup_event_on_day(storage, raw)
        if dup is not None:
            skipped.append({"title": title, "why": "duplicate",
                            "day": _dup_day_of(raw), "existing_id": dup.get("id")})
            logger.info("extractor: %r already on %s as %s", title,
                        _dup_day_of(raw), dup.get("id"))
            continue

        try:
            event = await create_event(
                storage, raw,
                actor=config.AUTO_ACTOR, source="auto",
                source_message_id=source_message_id,
            )
        except (TypeError, ValueError) as exc:
            skipped.append({"title": title, "why": f"rejected: {exc}"})
            logger.info("extractor: %r rejected by create_event: %s", title, exc)
            continue
        applied.append(event)
        logger.info("extractor: wrote %r on %s (confidence %.2f)",
                    title, _dup_day_of(raw), confidence)

    return {"ok": True, "applied": applied, "skipped": skipped,
            "candidates_seen": len(candidates)}
