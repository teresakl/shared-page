"""每年都过的日子：铺几年、重复启动不写重、写错的日期挡得住。"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import calendar_core as cal
import config
import seeder
from tests.support import MemoryStorage


class SeederTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.storage = MemoryStorage()
        await self.storage.connect()
        await cal.ensure_calendar_schema(self.storage)
        self.tmp = tempfile.TemporaryDirectory()
        self._saved = (config.SEED_FILE, config.SEED_YEARS)

    async def asyncTearDown(self):
        config.SEED_FILE, config.SEED_YEARS = self._saved
        self.tmp.cleanup()
        await self.storage.close()

    def write_seeds(self, items):
        path = Path(self.tmp.name) / "seeds.json"
        path.write_text(json.dumps(items, ensure_ascii=False), encoding="utf-8")
        config.SEED_FILE = str(path)
        return path

    async def test_no_file_configured_is_a_no_op(self):
        config.SEED_FILE = ""
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts, {"created": 0, "existing": 0, "skipped": 0})

    async def test_missing_file_does_not_crash(self):
        config.SEED_FILE = str(Path(self.tmp.name) / "nope.json")
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts["created"], 0)

    async def test_broken_json_does_not_crash(self):
        path = Path(self.tmp.name) / "bad.json"
        path.write_text("{ 这不是 json", encoding="utf-8")
        config.SEED_FILE = str(path)
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts["created"], 0)

    async def test_seeds_one_row_per_year(self):
        self.write_seeds([{"month_day": "03-15", "type": "birthday", "title": "生日"}])
        config.SEED_YEARS = 2
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts["created"], 2)

    async def test_running_twice_writes_nothing_new(self):
        self.write_seeds([{"month_day": "06-01", "type": "anniversary",
                           "title": "纪念日"}])
        config.SEED_YEARS = 2
        first = await seeder.seed(self.storage)
        second = await seeder.seed(self.storage)
        self.assertEqual(first["created"], 2)
        self.assertEqual(second["created"], 0)
        self.assertEqual(second["existing"], 2)

    async def test_all_day_at_local_midnight(self):
        self.write_seeds([{"month_day": "12-25", "type": "holiday", "title": "圣诞"}])
        config.SEED_YEARS = 1
        await seeder.seed(self.storage)
        rows = await cal.list_events(self.storage, from_value="2020-01-01",
                                     to_value="2099-12-31")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["precision"], "day")
        self.assertEqual(rows[0]["event_type"], "holiday")
        self.assertTrue(cal._anchor_date_of(rows[0]["starts_at"]).endswith("-12-25"))

    async def test_impossible_date_is_skipped_not_fatal(self):
        self.write_seeds([
            {"month_day": "02-30", "type": "holiday", "title": "不存在的日子"},
            {"month_day": "05-20", "type": "holiday", "title": "好日子"},
        ])
        config.SEED_YEARS = 1
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts["created"], 1)
        self.assertEqual(counts["skipped"], 1)

    async def test_malformed_month_day_is_skipped(self):
        self.write_seeds([{"month_day": "9-7", "title": "格式不对"}])
        counts = await seeder.seed(self.storage)
        self.assertEqual(counts["created"], 0)
        self.assertEqual(counts["skipped"], 1)

    async def test_seeded_events_wear_the_auto_handwriting(self):
        self.write_seeds([{"month_day": "03-15", "type": "birthday", "title": "生日"}])
        config.SEED_YEARS = 1
        await seeder.seed(self.storage)
        rows = await cal.list_events(self.storage, from_value="2020-01-01",
                                     to_value="2099-12-31")
        self.assertEqual(rows[0]["created_by"], config.AUTO_ACTOR)
        self.assertEqual(rows[0]["source"], "seed")


if __name__ == "__main__":
    unittest.main()
