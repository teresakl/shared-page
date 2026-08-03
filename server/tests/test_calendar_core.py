"""日历核心：事件、便签、未读、查重、tool 动作。

跑法（在 server/ 目录下）：

    python -m unittest discover -s tests -t .
"""

from __future__ import annotations

import json
import unittest

import calendar_core as cal
from tests.support import MemoryStorage


class Base(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.storage = MemoryStorage()
        await self.storage.connect()
        await cal.ensure_calendar_schema(self.storage)

    async def asyncTearDown(self):
        await self.storage.close()

    async def make(self, title, starts, ends=None, **kw):
        payload = {"title": title, "starts_at": starts}
        if ends:
            payload["ends_at"] = ends
        payload.update(kw)
        return await cal.create_event(
            self.storage, payload,
            actor=kw.pop("actor", "kitty"), source=kw.pop("source", "manual"),
        )


class EventTests(Base):
    async def test_create_read_update_delete(self):
        ev = await self.make("取快递", "2026-07-16T14:00:00+08:00",
                             "2026-07-16T15:00:00+08:00")
        self.assertTrue(ev["created"])
        self.assertEqual(ev["title"], "取快递")

        got = await cal.get_event(self.storage, ev["id"])
        self.assertEqual(got["title"], "取快递")

        updated = await cal.update_event(
            self.storage, ev["id"], {"title": "取快递（改）"},
            actor="kitty", source="manual")
        self.assertEqual(updated["title"], "取快递（改）")
        self.assertEqual(updated["revision"], 2)

        await cal.delete_event(self.storage, ev["id"], actor="kitty", source="manual")
        gone = await cal.get_event(self.storage, ev["id"])
        self.assertEqual(gone["status"], "deleted")
        # 软删：列表里查不到，但行还在
        self.assertEqual(await cal.list_events(self.storage, date_value="2026-07-16"), [])

    async def test_title_is_required(self):
        with self.assertRaises(ValueError):
            await self.make("   ", "2026-07-16T14:00:00+08:00")

    async def test_all_day_event_spans_to_next_midnight(self):
        """只给日期 = 整天事件，结束是次日零点（开区间）"""
        ev = await self.make("生日", "2026-03-15", precision="day")
        self.assertEqual(ev["precision"], "day")
        # 本地 3/15 00:00 == UTC 3/14 16:00；结束是次日零点
        self.assertTrue(ev["starts_at"].startswith("2026-03-14T16:00"))
        self.assertTrue(ev["ends_at"].startswith("2026-03-15T16:00"))

    async def test_day_is_computed_in_product_timezone(self):
        """这个工程踩过两次的坑：库里存 UTC，截字符串取日期会差一整天。

        UTC 8/24 16:00 在北京已经是 8/25，这条事件必须属于 25 号
        """
        ev = await self.make("生理期", "2026-08-24T16:00:00+00:00",
                             "2026-08-30T16:00:00+00:00")
        self.assertEqual(ev["starts_at"][:10], "2026-08-24")   # 存的是 UTC
        self.assertEqual(cal._anchor_date_of(ev["starts_at"]), "2026-08-25")

        on_25 = await cal.list_events(self.storage, date_value="2026-08-25")
        self.assertEqual(len(on_25), 1)
        on_24 = await cal.list_events(self.storage, date_value="2026-08-24")
        self.assertEqual(on_24, [])

    async def test_span_covers_every_day_in_between(self):
        await self.make("出差", "2026-07-20T09:00:00+08:00",
                        "2026-07-22T18:00:00+08:00")
        for day in ("2026-07-20", "2026-07-21", "2026-07-22"):
            self.assertEqual(len(await cal.list_events(self.storage, date_value=day)), 1, day)
        self.assertEqual(await cal.list_events(self.storage, date_value="2026-07-23"), [])


class NoteTests(Base):
    async def test_note_lifecycle(self):
        note = await cal.add_note(self.storage, body="记得带伞",
                                  author="kitty", anchor_date="2026-07-16")
        self.assertEqual(note["body"], "记得带伞")
        self.assertFalse(note["liked"])

        liked = await cal.update_note(self.storage, note["id"], {"liked": True},
                                      actor="master")
        self.assertTrue(liked["liked"])

        edited = await cal.update_note(self.storage, note["id"], {"body": "带伞和钥匙"},
                                       actor="kitty")
        self.assertEqual(edited["body"], "带伞和钥匙")

        await cal.delete_note(self.storage, note["id"], actor="kitty")
        self.assertEqual(await cal.list_notes(self.storage, date_value="2026-07-16"), [])

    async def test_empty_body_is_rejected(self):
        with self.assertRaises(ValueError):
            await cal.add_note(self.storage, body="   ", author="kitty",
                               anchor_date="2026-07-16")

    async def test_note_attached_to_event_keeps_its_day(self):
        ev = await self.make("看电影", "2026-07-18T20:00:00+08:00")
        note = await cal.add_note(self.storage, body="popcorn 交给你",
                                  author="master", event_id=ev["id"])
        self.assertEqual(note["anchor_date"], "2026-07-18")

    async def test_deleting_event_keeps_the_note(self):
        """外键写的是 ON DELETE SET NULL，但删事件是软删、触发不了外键。
        行为上便签要留下来（这是设计），这条测试钉住它"""
        ev = await self.make("组会", "2026-07-19T10:00:00+08:00")
        await cal.add_note(self.storage, body="带笔记本", author="kitty",
                           event_id=ev["id"])
        await cal.delete_event(self.storage, ev["id"], actor="kitty", source="manual")
        left = await cal.list_notes(self.storage, date_value="2026-07-19")
        self.assertEqual(len(left), 1)


class UnseenTests(Base):
    async def test_kitty_side_lights_up_and_can_be_cleared(self):
        """AI 那边改了、人这边还没看 —— 前端的感叹号画在这些天上"""
        await self.make("体检", "2026-07-28T09:00:00+08:00",
                        actor="master", source="manual")
        days = await cal.list_unseen_days(self.storage)
        self.assertEqual(days, ["2026-07-28"])

        cleared = await cal.mark_day_seen(self.storage, "2026-07-28")
        self.assertGreaterEqual(cleared, 1)
        self.assertEqual(await cal.list_unseen_days(self.storage), [])

    async def test_moving_an_event_lights_both_days(self):
        """挪日程：原来那天和新那天都要亮 —— 靠 update 快照里的 prev_span"""
        ev = await self.make("答辩", "2026-08-11T10:00:00+08:00",
                             actor="master", source="manual")
        await cal.mark_day_seen(self.storage, "2026-08-11")
        self.assertEqual(await cal.list_unseen_days(self.storage), [])

        await cal.update_event(
            self.storage, ev["id"],
            {"starts_at": "2026-08-13T10:00:00+08:00",
             "ends_at": "2026-08-13T11:00:00+08:00"},
            actor="master", source="manual")
        self.assertEqual(await cal.list_unseen_days(self.storage),
                         ["2026-08-11", "2026-08-13"])

    async def test_her_own_edits_do_not_light_her_side(self):
        await self.make("买菜", "2026-07-29T09:00:00+08:00",
                        actor="kitty", source="manual")
        self.assertEqual(await cal.list_unseen_days(self.storage), [])


class DedupTests(Base):
    """同日查重 —— 只给自动写入路用。规则见 calendar_core._dup_event_on_day"""

    async def check(self, existing_title, new_title, day="2026-08-12",
                    new_day=None):
        await self.make(existing_title, f"{day}T10:00:00+08:00")
        payload = {"title": new_title,
                   "starts_at": f"{new_day or day}T15:00:00+08:00"}
        return await cal._dup_event_on_day(self.storage, payload)

    async def test_exact_same_title_same_day(self):
        self.assertIsNotNone(await self.check("答辩", "答辩"))

    async def test_new_title_contains_existing(self):
        self.assertIsNotNone(await self.check("答辩", "下周三答辩"))

    async def test_existing_title_contains_new(self):
        self.assertIsNotNone(await self.check("下周三答辩", "答辩"))

    async def test_whitespace_is_ignored(self):
        self.assertIsNotNone(await self.check("去拿快递", "去 拿 快递"))

    async def test_fullwidth_space_is_ignored(self):
        self.assertIsNotNone(await self.check("去拿快递", "去　拿快递"))

    async def test_case_is_ignored(self):
        self.assertIsNotNone(await self.check("Standup", "standup"))

    async def test_different_titles_are_not_duplicates(self):
        self.assertIsNone(await self.check("答辩", "牙医"))

    async def test_same_title_different_day_is_not_a_duplicate(self):
        self.assertIsNone(await self.check("答辩", "答辩", new_day="2026-08-13"))

    async def test_deleted_event_does_not_block(self):
        ev = await self.make("答辩", "2026-08-12T10:00:00+08:00")
        await cal.delete_event(self.storage, ev["id"], actor="kitty", source="manual")
        hit = await cal._dup_event_on_day(
            self.storage, {"title": "答辩", "starts_at": "2026-08-12T15:00:00+08:00"})
        self.assertIsNone(hit)

    async def test_single_char_title_does_not_swallow_the_day(self):
        """「累」这种一个字的标题不该把一整天的事都判成重复"""
        self.assertIsNone(await self.check("累", "我今天很累"))
        self.assertIsNone(await self.check("我今天很累", "累"))

    async def test_manual_events_also_count_as_duplicates(self):
        """查重不区分来源：用户自己手写过的，自动路就别再写一条"""
        hit = await self.check("答辩", "答辩")
        self.assertEqual(hit["created_by"], "kitty")
        self.assertEqual(hit["source"], "manual")

    async def test_timezone_edge_uses_product_day(self):
        """UTC 8/24 16:00 = 北京 8/25。查重必须查北京那天"""
        await self.make("生理期", "2026-08-24T16:00:00+00:00")
        hit = await cal._dup_event_on_day(
            self.storage, {"title": "生理期", "starts_at": "2026-08-25T09:00:00+08:00"})
        self.assertIsNotNone(hit)
        miss = await cal._dup_event_on_day(
            self.storage, {"title": "生理期", "starts_at": "2026-08-24T09:00:00+08:00"})
        self.assertIsNone(miss)

    async def test_unparseable_time_returns_none_instead_of_raising(self):
        hit = await cal._dup_event_on_day(
            self.storage, {"title": "答辩", "starts_at": "不是时间"})
        self.assertIsNone(hit)


class ToolTests(Base):
    """AI 那侧的入口。动作表：list / see / create / update / delete / comment"""

    async def run_tool(self, **args):
        out = await cal.execute_calendar_tool(self.storage, args)
        return json.loads(out) if isinstance(out, str) else out

    async def test_create_then_list(self):
        made = await self.run_tool(action="create", title="牙医",
                                   starts_at="2026-07-20T10:00:00+08:00",
                                   ends_at="2026-07-20T11:00:00+08:00")
        self.assertTrue(made["ok"])
        listed = await self.run_tool(action="list", date="2026-07-20")
        self.assertEqual(listed["count"], 1)

    async def test_comment_lands_on_the_day(self):
        out = await self.run_tool(action="comment", date="2026-07-21",
                                  comment="别忘了带病历")
        self.assertTrue(out["ok"])
        notes = await cal.list_notes(self.storage, date_value="2026-07-21")
        self.assertEqual(len(notes), 1)

    async def test_get_is_an_alias_of_see(self):
        made = await self.run_tool(action="create", title="组会",
                                   starts_at="2026-07-22T10:00:00+08:00")
        one = await self.run_tool(action="get", event_id=made["event"]["id"])
        self.assertTrue(one["ok"])
        self.assertEqual(one["event"]["title"], "组会")

    async def test_like_is_an_alias_of_update(self):
        note = await cal.add_note(self.storage, body="早点睡", author="kitty",
                                  anchor_date="2026-07-23")
        out = await self.run_tool(action="like", note_id=note["id"])
        self.assertTrue(out["comment"]["liked"])

    async def test_update_and_delete_a_note_by_id(self):
        note = await cal.add_note(self.storage, body="旧的", author="kitty",
                                  anchor_date="2026-07-24")
        edited = await self.run_tool(action="update", note_id=note["id"],
                                     comment="新的")
        self.assertEqual(edited["comment"]["body"], "新的")
        await self.run_tool(action="delete", note_id=note["id"])
        self.assertEqual(await cal.list_notes(self.storage, date_value="2026-07-24"), [])

    async def test_unknown_action_reports_instead_of_raising(self):
        out = await self.run_tool(action="explode")
        self.assertFalse(out["ok"])
        self.assertIn("unknown action", out["error"])

    async def test_see_without_a_page_image_degrades_to_text(self):
        await self.run_tool(action="create", title="散步",
                            starts_at="2026-07-25T18:00:00+08:00")
        result = await cal.execute_calendar_see(self.storage, {"date": "2026-07-25"})
        self.assertIn("散步", result.text)
        self.assertIsNone(result.image_path)


if __name__ == "__main__":
    unittest.main()


class EnvBlockTests(Base):
    """环境块 —— 每轮对话塞进上下文的那段「此刻日历上有什么」"""

    def at(self, hour, minute=0):
        from datetime import datetime, timezone
        return datetime(2026, 8, 3, hour, minute, tzinfo=cal._BJ).astimezone(timezone.utc)

    async def test_empty_calendar_renders_nothing(self):
        """什么都没有的时候不要往上下文里塞一个空壳"""
        d = await cal.render_env_block(self.storage, now=self.at(17, 30))
        self.assertEqual(d.text, "")

    async def test_event_in_progress_shows_up_as_now(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        d = await cal.render_env_block(self.storage, now=self.at(17, 30), include_new=False)
        self.assertIn("[NOW]", d.text)
        self.assertIn("17:00–18:00 看牙医", d.text)

    async def test_same_event_is_not_now_before_it_starts(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        d = await cal.render_env_block(self.storage, now=self.at(16, 30), include_new=False)
        self.assertNotIn("[NOW]", d.text)
        self.assertIn("[TODAY]", d.text)

    async def test_it_leaves_when_it_is_over(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        d = await cal.render_env_block(self.storage, now=self.at(18, 1), include_new=False)
        self.assertNotIn("[NOW]", d.text)

    async def test_all_day_event_is_never_now(self):
        """「全天」没有「正在」可言，只进 [TODAY]"""
        await self.make("生理期", "2026-08-03", precision="day")
        d = await cal.render_env_block(self.storage, now=self.at(17, 30), include_new=False)
        self.assertNotIn("[NOW]", d.text)
        self.assertIn("08-03 全天 生理期", d.text)

    async def test_tomorrow_does_not_show_up(self):
        await self.make("明天的事", "2026-08-04T10:00:00+08:00")
        d = await cal.render_env_block(self.storage, now=self.at(17, 30), include_new=False)
        self.assertEqual(d.text, "")

    async def test_an_event_appears_in_only_one_section(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00",
                        actor="kitty")
        d = await cal.render_env_block(self.storage, now=self.at(17, 30))
        self.assertEqual(d.text.count("看牙医"), 1)
        self.assertIn("[NEW][NOW]", d.text)

    async def test_marking_seen_clears_the_new_section(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        first = await cal.render_env_block(self.storage, now=self.at(17, 30))
        self.assertIn("[NEW]", first.text)
        self.assertTrue(first.change_ids)

        await cal.complete_calendar_delivery(self.storage, first)
        second = await cal.render_env_block(self.storage, now=self.at(17, 30))
        self.assertNotIn("[NEW]", second.text)
        self.assertIn("[NOW]", second.text)

    async def test_include_new_false_never_reports_changes(self):
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        d = await cal.render_env_block(self.storage, now=self.at(17, 30), include_new=False)
        self.assertNotIn("[NEW]", d.text)
        self.assertEqual(d.change_ids, ())

    async def test_boundary_is_half_open(self):
        """起点那一刻算进行中，终点那一刻已经结束 —— 跟这个工程别处的区间规矩一致"""
        await self.make("看牙医", "2026-08-03T17:00:00+08:00", "2026-08-03T18:00:00+08:00")
        at_start = await cal.render_env_block(self.storage, now=self.at(17, 0), include_new=False)
        at_end = await cal.render_env_block(self.storage, now=self.at(18, 0), include_new=False)
        self.assertIn("[NOW]", at_start.text)
        self.assertNotIn("[NOW]", at_end.text)
