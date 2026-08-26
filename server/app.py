"""FastAPI 入口：挂 calendar 路由 + 启动建表。

跑起来就一条：

    CALENDAR_TOKEN=<你的token> uvicorn app:app --host 0.0.0.0 --port 8787

路径布局跟 iOS 端约定一致：base URL = http://<host>:<port>/api/v1/calendar
（前端 CalendarSecrets 里填的就是这一段，后面拼 /events /notes /unseen /pages…）。
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI

import config
import push
import routes
import seeder
from calendar_core import Storage

# Token is optional. Local web starts without one.
# Set CALENDAR_TOKEN if you expose this beyond your own machine.


@asynccontextmanager
async def lifespan(app: FastAPI):
    storage = Storage(config.CALENDAR_DB)
    await storage.connect()                        # 连库 + calendar 四张表
    await push.ensure_push_schema(storage._conn)   # push_devices（模块没开也建，空着无害）
    await seeder.seed(storage)                     # 生日/纪念日/节日（没配种子文件就是空转）
    app.state.storage = storage
    yield
    await storage.close()


app = FastAPI(title="couple-calendar", lifespan=lifespan)
app.include_router(routes.router, prefix="/api/v1")
app.include_router(push.router, prefix="/api/v1")
