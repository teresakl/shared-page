"""测试共用的假 storage。

真的 Storage 要连磁盘文件，测试用内存库就够 —— 核心函数只认 ``_conn``
这一个属性，所以这里也只提供它（外加 get/set_setting，个别路径会问）。
"""

from __future__ import annotations

import aiosqlite


class MemoryStorage:
    def __init__(self) -> None:
        self._conn = None
        self.settings: dict = {}

    async def connect(self) -> None:
        self._conn = await aiosqlite.connect(":memory:")
        self._conn.row_factory = aiosqlite.Row

    async def close(self) -> None:
        if self._conn is not None:
            await self._conn.close()

    async def get_setting(self, key):
        return self.settings.get(key)

    async def set_setting(self, key, value) -> None:
        self.settings[key] = value
