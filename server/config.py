"""环境变量都在这一个文件里，进程启动时读一次。

必填只有一个：CALENDAR_TOKEN —— 它是整个服务唯一那道门。
其余都有默认值；APNS_* 四件缺任何一件，推送模块整体关闭（一切照常，只是不响）。
"""

from __future__ import annotations

import os
from pathlib import Path

# ---- 鉴权 ----
# 前端和所有 REST 调用都带 X-Calendar-Token 头，值必须等于它。
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
# 跟 app 界面上的标签一致；填了之后手机推送和 AI 读到的文字里就都是你们自己的名字。
#   ASSISTANT_NAME：AI 那侧。人在手机推送里看到的就是它
#                   （「ASSISTANT 贴了一张便签：明天记得吃药」）
#   USER_NAME：人那侧。AI 用 see 动作看这一页时读到的就是它
ASSISTANT_NAME: str = os.environ.get("CALENDAR_ASSISTANT_NAME", "").strip() or "ASSISTANT"
USER_NAME: str = os.environ.get("CALENDAR_USER_NAME", "").strip() or "USER"

# ---- 自动抽取（可选模块，extractor.py）----
# 把聊天里的一句话喂进来，它判断有没有「未来的安排」，有就自己写进日历。
# 前三个缺任何一个，整个模块就是关的（服务照常跑，只是不会自动记事）。
# base_url 是任何 OpenAI 兼容接口的根，代码里会拼 /chat/completions。
EXTRACTOR_BASE_URL: str = os.environ.get("EXTRACTOR_BASE_URL", "").strip()
EXTRACTOR_API_KEY: str = os.environ.get("EXTRACTOR_API_KEY", "").strip()
EXTRACTOR_MODEL: str = os.environ.get("EXTRACTOR_MODEL", "").strip()

# 置信度门槛：模型对「下周三答辩」很确定(0.9)，对「这周末想去逛街」没那么确定(0.6)。
# 低于这个数直接丢掉。想让它更爱记事就调低，想让它矜持就调高。
EXTRACTOR_MIN_CONFIDENCE: float = float(
    os.environ.get("EXTRACTOR_MIN_CONFIDENCE", "").strip() or 0.6)
# 太短的消息不送，省掉「好」「嗯」「在吗」这类的模型调用。
# 默认 4：中文里「周三答辩」「明天考试」这种四个字就是一件完整的事，
# 门槛设高了会把真安排挡在外面（踩过：设 6 的时候「下周三答辩」进不来）
EXTRACTOR_MIN_CHARS: int = int(os.environ.get("EXTRACTOR_MIN_CHARS", "").strip() or 4)
EXTRACTOR_TIMEOUT: float = float(os.environ.get("EXTRACTOR_TIMEOUT", "").strip() or 20)

# 自动写入的事件挂在谁名下。前端认三种笔迹：人、AI、以及其余一律画成 AUTO 那种灰色，
# 所以这个值只要不是 "kitty" / "master" / "assistant" 就会显示成 AUTO
AUTO_ACTOR: str = os.environ.get("CALENDAR_AUTO_ACTOR", "").strip() or "auto"

# ---- 每年都过的日子（可选模块，seeder.py）----
# 指向一个 JSON 文件（数组，每项 {month_day, type, title}），服务启动时铺进日历。
# 不配就整个模块不启用。格式见 seeder.py 头部
SEED_FILE: str = os.environ.get("CALENDAR_SEED_FILE", "").strip()
SEED_YEARS: int = int(os.environ.get("CALENDAR_SEED_YEARS", "").strip() or 2)

# ---- 推送（可选模块）----
# APNs Auth Key（.p8）对 sandbox / production 两个环境通用，一把钥匙就够。
APNS_KEY_PATH: str = os.environ.get("APNS_KEY_PATH", "").strip()
APNS_KEY_ID: str = os.environ.get("APNS_KEY_ID", "").strip()
APNS_TEAM_ID: str = os.environ.get("APNS_TEAM_ID", "").strip()
APNS_BUNDLE_ID: str = os.environ.get("APNS_BUNDLE_ID", "").strip()


def require_token() -> str:
    """REST 服务启动前必须有 token。没配就报错退出，顺手把生成命令给出来。"""
    if not CALENDAR_TOKEN:
        raise SystemExit(
            "CALENDAR_TOKEN is not set. Generate one with:\n"
            '  python -c "import secrets; print(secrets.token_hex(32))"\n'
            "then start the server with CALENDAR_TOKEN=<value>."
        )
    return CALENDAR_TOKEN
