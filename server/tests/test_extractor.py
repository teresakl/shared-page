"""自动抽取：门槛、查重、太短的消息、模型抽风时的表现。

模型调用整个打桩 —— 单元测试不该联网，也不该花钱。真模型的行为
另外用真句子验过（见 README 里那张表）。
"""

from __future__ import annotations

import unittest
from unittest import mock

import calendar_core as cal
import config
import extractor
from tests.support import MemoryStorage


def candidate(title, starts, confidence, **kw):
    item = {"title": title, "starts_at": starts, "confidence": confidence,
            "precision": kw.pop("precision", "day")}
    item.update(kw)
    return item


class ExtractorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.storage = MemoryStorage()
        await self.storage.connect()
        await cal.ensure_calendar_schema(self.storage)
        # 把三件套填上，让 enabled() 为真；用完在 tearDown 还原
        self._saved = (config.EXTRACTOR_BASE_URL, config.EXTRACTOR_API_KEY,
                       config.EXTRACTOR_MODEL, config.EXTRACTOR_MIN_CONFIDENCE)
        config.EXTRACTOR_BASE_URL = "https://example.invalid"
        config.EXTRACTOR_API_KEY = "test-key"
        config.EXTRACTOR_MODEL = "test-model"

    async def asyncTearDown(self):
        (config.EXTRACTOR_BASE_URL, config.EXTRACTOR_API_KEY,
         config.EXTRACTOR_MODEL, config.EXTRACTOR_MIN_CONFIDENCE) = self._saved
        await self.storage.close()

    async def run_with(self, candidates, text="下周三答辩"):
        with mock.patch.object(extractor, "_ask_model",
                               mock.AsyncMock(return_value=candidates)):
            return await extractor.extract_and_apply(self.storage, text)

    async def test_confident_candidate_is_written(self):
        out = await self.run_with([candidate("答辩", "2026-08-12T00:00:00+08:00", 0.9)])
        self.assertEqual(len(out["applied"]), 1)
        self.assertEqual(out["applied"][0]["title"], "答辩")
        self.assertEqual(out["applied"][0]["source"], "auto")
        self.assertEqual(out["applied"][0]["created_by"], config.AUTO_ACTOR)

    async def test_below_threshold_is_dropped_and_says_so(self):
        out = await self.run_with([candidate("逛街", "2026-08-08T00:00:00+08:00", 0.4)])
        self.assertEqual(out["applied"], [])
        self.assertEqual(len(out["skipped"]), 1)
        self.assertIn("below threshold", out["skipped"][0]["why"])

    async def test_threshold_is_inclusive(self):
        """正好等于门槛要放行 —— 判定写的是「小于才丢」"""
        config.EXTRACTOR_MIN_CONFIDENCE = 0.6
        out = await self.run_with([candidate("逛街", "2026-08-08T00:00:00+08:00", 0.6)])
        self.assertEqual(len(out["applied"]), 1)

    async def test_duplicate_is_skipped_and_names_the_existing_one(self):
        first = await self.run_with([candidate("答辩", "2026-08-12T00:00:00+08:00", 0.9)])
        again = await self.run_with([candidate("下周三答辩", "2026-08-12T09:00:00+08:00", 0.9)])
        self.assertEqual(again["applied"], [])
        self.assertEqual(again["skipped"][0]["why"], "duplicate")
        self.assertEqual(again["skipped"][0]["existing_id"], first["applied"][0]["id"])

    async def test_another_thing_on_the_same_day_still_goes_in(self):
        await self.run_with([candidate("答辩", "2026-08-12T00:00:00+08:00", 0.9)])
        other = await self.run_with([candidate("牙医", "2026-08-12T15:00:00+08:00", 0.9)])
        self.assertEqual(len(other["applied"]), 1)

    async def test_missing_start_time_is_skipped(self):
        out = await self.run_with([{"title": "某件事", "confidence": 0.9}])
        self.assertEqual(out["applied"], [])
        self.assertIn("missing", out["skipped"][0]["why"])

    async def test_short_text_never_reaches_the_model(self):
        called = mock.AsyncMock(return_value=[])
        with mock.patch.object(extractor, "_ask_model", called):
            out = await extractor.extract_and_apply(self.storage, "好的")
        called.assert_not_awaited()
        self.assertEqual(out["reason"], "text too short")

    async def test_at_most_three_candidates_per_message(self):
        many = [candidate(f"事情{i}", f"2026-09-{i + 1:02d}T10:00:00+08:00", 0.9)
                for i in range(5)]
        out = await self.run_with(many)
        self.assertEqual(len(out["applied"]), 3)

    async def test_one_bad_candidate_does_not_kill_the_rest(self):
        out = await self.run_with([
            {"title": "坏的", "starts_at": "不是时间", "confidence": 0.9},
            candidate("好的那条", "2026-08-20T10:00:00+08:00", 0.9),
        ])
        self.assertEqual(len(out["applied"]), 1)
        self.assertEqual(out["applied"][0]["title"], "好的那条")

    async def test_disabled_module_reports_instead_of_crashing(self):
        config.EXTRACTOR_API_KEY = ""
        out = await extractor.extract_and_apply(self.storage, "下周三答辩")
        self.assertFalse(out["ok"])
        self.assertIn("not configured", out["error"])

    async def test_model_failure_is_swallowed(self):
        """模型超时/返回垃圾都不该把这一路搞崩，返回空就好"""
        with mock.patch.object(extractor, "_ask_model",
                               mock.AsyncMock(side_effect=None, return_value=[])):
            out = await extractor.extract_and_apply(self.storage, "下周三答辩")
        self.assertTrue(out["ok"])
        self.assertEqual(out["applied"], [])


class PromptShapeTests(unittest.TestCase):
    """提示词里那几条硬规矩别被顺手改掉"""

    def test_prompt_covers_the_four_false_positive_families(self):
        """四类假阳性:已发生的、规律性的、别人的、还没定的"""
        for phrase in ("已经发生的", "规律性的事实", "别人的安排", "条件句"):
            self.assertIn(phrase, extractor.SYSTEM_PROMPT)

    def test_prompt_asks_for_json_only(self):
        self.assertIn("candidates", extractor.SYSTEM_PROMPT)
        self.assertIn("严格只输出一个 JSON 对象", extractor.SYSTEM_PROMPT)


if __name__ == "__main__":
    unittest.main()
