"""环境变量都在这一个文件里，进程启动时读一次。

CALENDAR_TOKEN 可选。本机 / 局域网默认不设，打开网页就能用。
如果要把服务穿透到公网，再设这把钥匙。
APNS_* 四件缺任何一件，推送模块整体关闭（一切照常，只是不响）。
"""

from __future__ import annotations

import os
from pathlib import Path

# ---- 鉴权 ----
# 空 = 本地开门。设了之后，前端和 REST 都要带 X-Calendar-Token。
CALENDAR_TOKEN: str = os.environ.get("CALENDAR_TOKEN", "").strip()

# ---- 存储 ----
CALENDAR_DB: str = os.environ.get("CALENDAR_DB", "./data/calendar.db").strip()
PAGES_DIR: Path = Path(os.environ.get("CALENDAR_PAGES_DIR", "./data/pages").strip())

# ---- 时区 ----
# 全服务一个产品时区（设计决定：这是两个人 + 一个 AI 的日历，不是多时区 SaaS）。
# 库里存的时间戳一律 UTC ISO，所有「哪一天」的判断都换算到这个时区再算。
CALENDAR_TZ: str = os.environ.get("CALENDAR_TZ", "Asia/Shanghai").strip() or "Asia/Shanghai"

# ---- 两边的称呼 ----
# 一本日历两个人用，各自在对方眼里叫什么。没填就是 USER / ASSISTANT 这两个占位符，
# 跟 app 界面上的标签一致；填了之后推送和 AI 读到的文字里就都是你们自己的名字。
#   ASSISTANT_NAME：AI 那侧
#   USER_NAME：人那侧。AI 用 see 动作看这一页时读到的就是它
ASSISTANT_NAME: str = os.environ.get("CALENDAR_ASSISTANT_NAME", "").strip() or "ASSISTANT"
USER_NAME: str = os.environ.get("CALENDAR_USER_NAME", "").strip() or "USER"

# ---- 自动抽取（可选模块，extractor.py）----
EXTRACTOR_BASE_URL: str = os.environ.get("EXTRACTOR_BASE_URL", "").strip()
EXTRACTOR_API_KEY: str = os.environ.get("EXTRACTOR_API_KEY", "").strip()
EXTRACTOR_MODEL: str = os.environ.get("EXTRACTOR_MODEL", "").strip()

EXTRACTOR_MIN_CONFIDENCE: float = float(
    os.environ.get("EXTRACTOR_MIN_CONFIDENCE", "").strip() or 0.6)
EXTRACTOR_MIN_CHARS: int = int(os.environ.get("EXTRACTOR_MIN_CHARS", "").strip() or 4)
EXTRACTOR_TIMEOUT: float = float(os.environ.get("EXTRACTOR_TIMEOUT", "").strip() or 20)

AUTO_ACTOR: str = os.environ.get("CALENDAR_AUTO_ACTOR", "").strip() or "auto"

# ---- 每年都过的日子（可选模块，seeder.py）----
SEED_FILE: str = os.environ.get("CALENDAR_SEED_FILE", "").strip()
SEED_YEARS: int = int(os.environ.get("CALENDAR_SEED_YEARS", "").strip() or 2)

# ---- 推送（可选模块）----
APNS_KEY_PATH: str = os.environ.get("APNS_KEY_PATH", "").strip()
APNS_KEY_ID: str = os.environ.get("APNS_KEY_ID", "").strip()
APNS_TEAM_ID: str = os.environ.get("APNS_TEAM_ID", "").strip()
APNS_BUNDLE_ID: str = os.environ.get("APNS_BUNDLE_ID", "").strip()


def token_required() -> bool:
    return bool(CALENDAR_TOKEN)


def require_token() -> str:
    """Hard gate kept for scripts. The local web server does not call this."""
    if not CALENDAR_TOKEN:
        raise SystemExit(
            "CALENDAR_TOKEN is not set. For a public tunnel, generate one with:\n"
            '  python -c "import secrets; print(secrets.token_hex(32))"\n'
            "then start the server with CALENDAR_TOKEN=<value>."
        )
    return CALENDAR_TOKEN
