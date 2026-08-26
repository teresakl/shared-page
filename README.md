# 一本和 AI 共用的日历

本仓库是 [KKarsyline/shared-page](https://github.com/KKarsyline/shared-page) 的 fork。原作者的界面是 iOS App；这里改成了**本地网页**（电脑和同一局域网里的手机浏览器都能打开）。iOS 工程请到[原仓库](https://github.com/KKarsyline/shared-page)下载，本 fork 不再包含。

一本可以与你的AI一起管理的手帐风日历本，加一个自己部署的后端。特别的地方是：**你的 AI 也能用它**——ta 能读你写的安排、自己往上面记事、贴便签、还能看见你做的手帐和记录（网页上那一页排出来的样子，包括上面的贴纸、照片、便签）。

日历上有两种笔迹：你的，和 AI 的。原仓库还有一条可选的聊天抽取（AUTO），本 fork 的网页不接，也不假装已经接上。

<p align="center">
  <img src="docs/month.png" width="300" alt="月视图">
  <img src="docs/day.png" width="300" alt="日视图">
</p>

*（截图是本 fork 本地网页的示范数据，USER / ASSISTANT。本机打开即可，不必先填钥匙。）*

---

## 这个日历适合谁

做它的起因是我想和自己的 AI 伴侣共用一本日历。不过如果你只是想让任何接了 MCP 的 AI agent 帮你管日程，它一样能用，界面上的标签就是 `USER` 和 `ASSISTANT`，你可以改成任何名字。

它**不是**给团队或者多用户场景准备的。整个服务只有一个 token、一本日历、一个时区。这是有意的取舍，不是没做完。

---

## 一分钟看懂它怎么转

```
    你的浏览器                  你的服务器                   你的 AI
  ┌──────────┐              ┌─────────────┐            ┌──────────┐
  │ 写事件    │─── REST ────▶│             │◀── MCP ───│ 读日历    │
  │ 贴便签    │              │  SQLite     │            │ 写事件    │
  │ 贴贴纸    │              │  一个文件    │            │ 贴便签    │
  │ 贴照片    │              │             │            │ 看整页图  │
  │ 整页渲染  │─── 上传 ────▶│             │───────────▶│ 给便签点心 │
  └──────────┘              └─────────────┘            └──────────┘
       ▲                            │
       └────── 同一局域网访问 ───────┘
```

所有东西都在你自己的机器上。没有云服务，没有账号体系，没有第三方。电脑打开本地网页即可；同一局域网的手机用浏览器也能进。原作者的 iOS App 不在本 fork 里。

如果你有自己的聊天管道（不只是让 AI 通过 MCP 主动查），还可以往里加一条：每轮对话取一次「此刻日历上有什么」贴进上下文。你标了下午五点看牙医，那一小时里 AI 就一直知道你在牙医那儿。

---

## AI 能做什么

后端自带一个 MCP server，接上之后你的 AI 就有一个叫 `calendar` 的工具。六个动作：

### `list` — 看有什么安排

```json
{"action": "list", "from": "2026-08-01", "to": "2026-08-31"}
```

返回那段时间的事件。**顺带还会返回 `new_changes`**——就是「你改了但我还没看过」的那些，每条前面带 `[NEW]`。这是让 AI 每次对话都知道日历变了的办法：在组装上下文的时候调一次 `list`，把结果塞进去，AI 就知道你昨晚加了什么。读过之后标记会自动熄灭，同一件事不会被反复提醒。

（自动注入这一步要你自己在聊天管道里接。数据和「哪些是新的」这套账都是现成的，接线归你。）

### `see` — 看一整页

```json
{"action": "see", "date": "2026-08-09"}
```

这是这个项目最特别的一个动作。它返回两样东西：

- **一张图**——网页上那一天渲染出来的整页 PNG。贴纸贴在哪、照片摆成什么角度、便签怎么错开、手写字什么样，全都在里面。AI 看到的和你眼睛看到的是同一个东西。
- **一段文字**——那天的事件和便签的纯文本，附带一句「这张图是几点渲染的，图之后你又改了什么」。

不带 `date` 就是今天。带 `event_id` 的话它变成「看这一条的详情」。

图是网页在退出那一天的时候自己渲染上传的，所以总是你最后看到的样子。那天还没渲染过就只有文字，不会报错。

### `create` — 记一件事

```json
{"action": "create", "title": "牙医", "starts_at": "2026-08-10T10:00:00+08:00", "ends_at": "2026-08-10T11:00:00+08:00"}
```

`ends_at` 不给就默认一小时。跨天的事件写清楚起止就行，日历上会画成一条横过去的色带。

**`ends_at` 是开区间**——一件事「到 8 月 16 日」，`ends_at` 要写 8 月 17 日。整天的事件把 `precision` 写成 `"day"`，起点只给日期就行。

`event_type` 前端认三种：`anniversary` 和 `birthday` 会在那天盖一个爱心章；`period` 画成一条横带。别的值不影响显示，随便写，当标签用。

### `update` — 改一件事，或者改一张便签

```json
{"action": "update", "event_id": "cal_xxx", "starts_at": "...", "ends_at": "..."}
```

挪日子的时候**起止要一起给**——只给新起点的话旧终点还留在原地，起点跑到终点后面会被拒。

带 `note_id` 的话它改的是便签：`comment` 改文字，`liked: true` 给便签点一颗心（这个是双向的，你也能给 AI 的便签点心）。

### `delete` — 撕掉

带 `event_id` 删事件，带 `note_id` 撕便签。都是软删，行还在库里，只是不再出现。

### `comment` — 贴一张便签

```json
{"action": "comment", "date": "2026-08-10", "comment": "别忘了带病历"}
```

只给 `date` 就贴在那一天。原 MCP 仍接受 `event_id`，但**本网页不会显示「绑在哪条日程」**——便签只出现在当天纸面上。

一张纸大概能写 18 个汉字（两行，每行 9 个），写不下就拆成两张。

### 怎么接上

后端起来之后，MCP 入口有两种跑法：

```bash
# stdio（给 Claude Desktop / Claude Code 这类）
python mcp_server.py

# streamable-http（给能连远程 MCP 的客户端）
python mcp_server.py --http --port 8788
```

Claude Desktop 的配置大概长这样：

```json
{
  "mcpServers": {
    "calendar": {
      "command": "/你的路径/server/.venv/bin/python",
      "args": ["/你的路径/server/mcp_server.py"],
      "env": {
        "CALENDAR_DB": "/你的路径/server/data/calendar.db"
      }
    }
  }
}
```

`command` 要指到你那个 venv 里的 python（依赖装在里面），别写成裸的 `python`——Claude Desktop 起进程的时候不走你的 shell 环境，多半找不到。MCP 这条路不读 `CALENDAR_TOKEN`，所以不用填。

---

## 网页上能做什么

打开后端之后，浏览器访问 `http://127.0.0.1:8787`（同一局域网的手机改成电脑的局域网 IP）。本机默认不用填钥匙，打开就是月视图。

### 写事件

日视图右下角加号，写标题、选时间。跨过大约 26 小时的事件，月视图格子里会画一条色带（同一格最多两条）。

### 贴便签

从右下角菜单撕一张纸。**按住整张纸拖动**可以上下左右挪；点一下选中（出现叉），再点文字才进入编辑。

双击 AI 留下的便签给它点一颗心。你的纸只能你改、你撕；AI 的纸你不改字、不撕，只点心。

### 贴贴纸和照片（只在日视图）

日视图加号 → 贴纸。贴纸栏是原作者那一套：网点猫、老相机、咖啡杯、票根、红心。贴上之后可以拖、删、转、缩放。

点加号从本机选照片，会嵌进拍立得相框。**没有** iOS 那种「从相册抠图烤成可复用贴纸」。

**月视图不能贴贴纸。** 原 iOS 月格子会缩略显示当天贴纸，网页没有这一层。

### Agent 怎么贴贴纸

MCP 的六个动作不管贴纸。贴纸走网页后端自己的 placed 口（先读再写，避免盖掉已有照片）：

```bash
# 1. 先取出这一天已经贴好的
curl -H "X-Calendar-Token: 你的token" \
  http://127.0.0.1:8787/api/v1/calendar/placed/2026-08-26

# 2. 把原 items 整份带上，末尾追加一张，再 PUT 回去
curl -X PUT -H "X-Calendar-Token: 你的token" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:8787/api/v1/calendar/placed/2026-08-26 \
  -d '{"items":[ ...已有的..., {
    "id":"新uuid",
    "kind":"sticker",
    "stickerID":"5713CA70-0000-4000-A000-000000000005",
    "x":210,"y":260,"scale":1,"rotation":-4
  }]}'
```

`stickerID` 对应贴纸栏那五张：`...0001` 网点猫、`...0002` 相机、`...0003` 杯子、`...0004` 票根、`...0005` 红心。人从贴纸栏点，AI 走这条 PUT。两边写进同一个文件。

### 整页渲染

从某一天退回月视图时，网页把那一天渲染成 PNG 传到后端。之后 AI 用 `see` 拿到这张图。还没渲染过就只有文字，不会报错。

### 本网页明确没有的

- iOS App、桌面小组件、APNs 推送
- 相册抠图烤成可复用贴纸
- 月视图贴贴纸 / 月格子缩略贴纸
- 便签绑到某一条日程（便签只出现在当天）
- 聊天网关自动从对话抽日程（下面那节原模块还在仓库里，网页不接）

---

## 系统自动记事（AUTO）——本网页不接

原仓库有一个可选的 `extractor`：你自己的聊天管道每收到一条用户消息，可以 POST 到 `/extract`，日历上长出灰色 `AUTO` 安排。

**本 fork 的本地网页没有接聊天网关，也不要求你接。** 不配那三个环境变量时，这个口返回 503，其余功能照常。下面只留给确实要自己接线的人。

### 怎么开

`extractor.py` 是可选模块，配三个环境变量才启用：

```bash
EXTRACTOR_BASE_URL=https://api.deepseek.com/v1   # 任何 OpenAI 兼容的接口
EXTRACTOR_API_KEY=你的key
EXTRACTOR_MODEL=deepseek-chat
```

不配的话服务照常跑，只是不会自动记事。

### 怎么接进你自己的网关

它不会自己去读你的聊天记录——你的对话在哪、长什么样，它不知道，也不该知道。**你在自己的聊天管道里，每收到一条用户消息往这儿打一次就行**：

```bash
curl -X POST http://你的服务器/api/v1/calendar/extract \
  -H "X-Calendar-Token: 你的token" \
  -H "Content-Type: application/json" \
  -d '{"text": "下周三答辩", "message_id": "msg_abc123"}'
```

如果你的网关是 Python 的，大概是这样一段：

```python
async def on_user_message(text: str, message_id: str) -> None:
    """用户消息落库之后调一次。不要 await 它 —— 见下面第一条"""
    try:
        async with httpx.AsyncClient(timeout=25) as cli:
            await cli.post(
                f"{CALENDAR_BASE}/extract",
                headers={"X-Calendar-Token": CALENDAR_TOKEN},
                json={"text": text, "message_id": message_id},
            )
    except Exception:
        logger.warning("calendar extract failed", exc_info=True)
        # 抽取失败就当这条消息没安排，绝不能影响正常回复


# 在你处理用户消息的地方：
asyncio.create_task(on_user_message(text, message_id))   # 丢到后台，别等它
```

**接的时候有五件事值得注意：**

1. **别放在回复链路上等它。** 这一步要调一次模型，两三秒到十几秒都可能。挂在回复前面的话，用户每说一句话都要多等这么久；更糟的是如果你给这一步设了超时上限，超时那些消息会被静默丢掉——完全看不出来。丢到后台任务里跑，回复该怎么走怎么走。

2. **只送真实的用户消息。** 系统提示、自动唤醒的合成消息、AI 自己的回复，都别送。一是浪费调用，二是 AI 说的「那我们下周三见」会被当成用户的安排记进去。

3. **一次只送一句，别送上下文。** 它判断的就是「这一句里有没有安排」。把历史一起送进去，早就聊过的旧安排会被反复提取出来。

4. **带上 `message_id`。** 它会写进事件的 `source_message_id` 字段。以后想知道「日历上这条是从哪句话来的」，一查就有。顺带也方便你自己做幂等——重试的时候不至于同一句话处理两遍（不过就算处理两遍，同日查重也会把第二次拦下）。

5. **短消息它自己会拦。** 少于 4 个字（`EXTRACTOR_MIN_CHARS`）的直接返回，不调模型，所以「好」「嗯」「在吗」不花钱。这个数别设太高——中文里「周三答辩」四个字就是一件完整的事，设成 6 的话「下周三答辩」都会被挡在外面。

返回里写清楚了每条候选的去向：写进去了、置信度不够被丢了、还是跟已有的事件重了。

```json
{
  "ok": true,
  "candidates_seen": 1,
  "applied": [{"id": "cal_xxx", "title": "答辩", "starts_at": "...", "created_by": "auto"}],
  "skipped": []
}
```

这条链路最怕的就是无声失败——「模型没抽出来」和「抽出来了但被门槛拦掉」在外面看起来一模一样，都是日历上什么都没发生。所以它把每一步都告诉你，日志里也各打一行。

### 怎么让 AI 知道「现在几点该干什么」

如果你有自己的聊天管道，最省事的是这个口——它把「此刻日历上有什么」渲染成一段现成的文字，你每轮组装上下文的时候取一次，贴进 system prompt 或者你自己的环境注入块：

```bash
curl "http://你的服务器/api/v1/calendar/env" -H "X-Calendar-Token: 你的token"
```

```json
{
  "text": "<calendar>\n[NEW]\n[NEW][NOW] 17:00–18:00 看牙医（USER新增）\n</calendar>",
  "change_ids": [42],
  "empty": false
}
```

把 `text` 原样贴进去就行。三段的意思：

- **`[NOW]`** — 此刻正在进行的。你标了下午五点到六点看牙医，那么这一小时里 AI 每一轮都会在自己的上下文里看到它，聊到一半问你「牙医那边怎么样」是自然的。整天的事件不进这一段——「全天」没有「正在」可言。
- **`[TODAY]`** — 今天其余的。
- **`[NEW]`** — 你改过、AI 还没看过的。一条事件只会出现在最靠前的那一段里，确认已读之后不重复出现。

日历上什么都没有的时候 `text` 是空字符串，别往上下文里塞一个空壳。

**关于 `[NEW]` 的熄灭**：默认取一次不会把它标成已读，因为注入这一步可能失败，不该白白把「用户改了什么」销掉。稳妥的做法是先取、确认这段文字真的用上了、再拿返回里的 `change_ids` 销账：

```bash
curl -X POST "http://你的服务器/api/v1/calendar/env/seen" \
  -H "X-Calendar-Token: 你的token" -H "Content-Type: application/json" \
  -d '{"change_ids": [42]}'
```

只想每轮补一遍当前状态、不想反复报新变化的话，用 `?new=false`，那样只出 `[NOW]` 和 `[TODAY]`。

### 想自己渲染的话

上面给出的是拼好的文字。如果你想用自己的口气跟你的 AI 说话，也可以拿原始数据自己拼。

日历后端替两边各记了一本账：

**AI 这边**——你改过、AI 还没看过的，会跟在 `list` 的返回里：

```json
{
  "ok": true,
  "events": [ ... ],
  "count": 3,
  "new_changes": [
    {
      "id": 42,
      "event_id": "cal_b52c1110a8b2430a",
      "action": "create",
      "actor": "kitty",
      "snapshot": { "title": "牙医", "starts_at": "2026-08-10T02:00:00+00:00", "...": "整条事件的快照" }
    }
  ]
}
```

`action` 是 `create` / `update` / `delete` / `comment` / `like` / `note_update` / `note_delete` 之一，`snapshot` 是那一刻整条事件（或便签）的样子。**怎么把它渲染成一句人话由你决定**——你自己的网关最清楚该用什么口气跟你的 AI 说话，所以这里只给结构化的数据，不替你措辞。最简单的做法是拼成一行塞进环境块：

```python
lines = [
    f"[NEW] {c['actor']} {c['action']} 了「{c['snapshot'].get('title', '')}」"
    for c in result["new_changes"]
]
```

在组装上下文的时候调一次 `list`，把这些塞进 system prompt 或者你的环境注入块，AI 就知道你昨晚加了什么。**读过之后这些标记会自动熄灭**，同一件事不会被反复提醒——这一步 `list` 自己做了，你不用管。

如果你的 AI 是通过 MCP 接的，直接让 ta 调 `calendar` 工具的 `list` 就行；如果你想在注入的时候自己拿，走 REST 的 `GET /events?from=&to=` 也可以，只是那条路不会自动熄灭标记。

**网页这边**——AI 改过、你还没看过的，前端用这两个口：

```
GET  /api/v1/calendar/unseen        → {"days": ["2026-08-10", "2026-08-15"], "count": 2}
POST /api/v1/calendar/unseen/seen  {"date": "2026-08-10"}
```

app 会在这些日子上画一个红色感叹号，你点进那一页看过之后就熄掉。跨天的事件是整条一起熄——你点进去看到的就是完整的那一段，剩下几天没有新信息。

### 它认得出什么

拿真模型跑过的一批：

| 你说的话 | 结果 |
|---|---|
| 下周三答辩 | ✅ 记在 8/12 |
| 这周末想去逛街 | ✅ 记在周六 |
| 8/9 放假回家 | ✅ 记在 8/9 |
| 16 号早上要赶高铁 | ✅ 记在 8/16 早上 |
| 明天早八有课 | ✅ 记在明天 8:00 |
| 昨天去了牙医 | 不记（已经发生的） |
| 每周三都有组会 | 不记（规律性的，不是某一次） |
| 我妈说下周来看我 | 不记（别人的安排） |
| 如果周末不下雨就去爬山 | 不记（还没定） |
| 改天一起看电影吧 | 不记（没有具体日子） |

相对时间它会自己换算——prompt 里每次都带着当前时间，所以「下周三」「16 号」「明天」都能算成真实日期。

### 置信度

模型对「下周三答辩」很确定（0.9），对「这周末想去逛街」就没那么确定（0.6）。低于门槛的直接丢掉，宁可漏记也别乱记——日历是每天要看的东西，里面多一条假的比少一条真的更烦人。

默认门槛 0.6。想让它记得多一些宽泛一些就把 `EXTRACTOR_MIN_CONFIDENCE` 调低，想让它记得少一些更准确一些就调高。

### 去重

自动写入的两条路（抽取器和下面的种子）在写之前都会看一眼：**这一天有没有已经有一件差不多的事**。标题去掉空格之后互相包含就算重复，跳过不写。

你自己手写的永远不查——同一天想记三条一样的，那是你的自由。

---

## 每年都过的日子

生日、纪念日、节日不用谁去记，写一次就该年年都在。`seeder.py` 干的就是这件事。

放一个 JSON 文件，指给 `CALENDAR_SEED_FILE`。仓库里有一份只作格式示范的 `server/seeds.example.json`，复制后改成你自己的日子，**不要把写了真实生日/纪念日的文件提交到 git**：

```json
[
  {"month_day": "03-15", "type": "birthday",    "title": "生日"},
  {"month_day": "06-01", "type": "anniversary", "title": "纪念日"},
  {"month_day": "12-25", "type": "holiday",     "title": "圣诞"}
]
```

在 `.env` 里写：

```bash
CALENDAR_SEED_FILE=./seeds.json
CALENDAR_SEED_YEARS=2
```

服务每次启动铺一遍，默认往后铺两年。重复启动不会写重。

只认公历。农历生日、春节中秋这些每年公历日期都不一样，自己在表里补当年的具体日期就行。

---

## 手机通知（可选，仅原仓库 iOS）

本 fork 不含 iOS，所以 APNs 推送不会走到网页上。如果你同时使用[原仓库的 iOS App](https://github.com/KKarsyline/shared-page)，仍可按原作者 README 里的 APNs 四项来配。缺任何一个，登记端点返回 503，其余功能一切照常。

---

## 跑起来

### 后端 + 本地网页

需要 Python 3.10 以上（建议 3.12）。网页和 API 同源，用 `web_app:app` 启动。

```bash
cd server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

cp .env.example .env
# 本机可以不填 CALENDAR_TOKEN。要做云端穿透时再生成一把：
#   python -c "import secrets; print(secrets.token_hex(32))"

set -a; source .env; set +a
uvicorn web_app:app --host 127.0.0.1 --port 8787
```

浏览器打开 `http://127.0.0.1:8787`。只想探活 API：`GET http://127.0.0.1:8787/api/v1/calendar/ping`，返回 `{"ok": true, "service": "calendar", "token_required": false}` 就是通了。

想先看到 README 那种示范页：另指一个空的 `CALENDAR_DB`，跑 `python seed_demo.py`，再启动。不要对着已经在用的库跑。

同一局域网的手机要打开时，把 `--host` 改成 `0.0.0.0`，手机浏览器填电脑的局域网 IP，例如 `http://192.168.x.x:8787`。没设钥匙就直接进；设了钥匙才要填。

数据全在 `data/calendar.db` 这一个文件里，整页图在 `data/pages/`，贴纸位置在 `data/placed/`。备份就是复制这几样。

**关于暴露到公网**：默认只绑本机。本机不设钥匙，打开就能用。如果做云端穿透（frp、Cloudflare Tunnel、公网反代），**建议设 `CALENDAR_TOKEN`**：REST 请求头对不上会 401，网页也会先要钥匙。不设钥匙就把日历裸放在公网上。

**但 MCP 的 http 口不校验 token**（`--http` 那条，端点是 `/mcp`）。它默认只绑 `127.0.0.1`，别改成 `0.0.0.0` 直接扔公网——要放出去的话，自己在反代那一层加一道鉴权。

### 跑测试

```bash
cd server
python -m unittest discover -s tests -t .
```

64 条，不需要额外装东西，不联网。

### iOS app

本 fork 去掉了 iOS。需要原生 App、模拟器样例数据或桌面小组件时，请到原作者仓库：

https://github.com/KKarsyline/shared-page

那里的 README 有 Xcode / xcodegen / TestFlight 的完整步骤。

### 换字体

网页里的手写字用的是[霞鹜文楷](https://github.com/lxgw/LxgwWenKai)（OFL）。想换成自己喜欢的手写体：把 ttf 放进 `web/assets/fonts/`，再改 `web/styles.css` 里的 `@font-face`。

---

## 已知的取舍

- **网页端不做离线缓存。** 没网就是空的。日历是要和另一个人对齐的东西，一份可能过期的本地副本比空白更麻烦。
- **全服务一个时区。** 库里存 UTC，所有「哪一天」的判断都换算到 `CALENDAR_TZ`。这是两个人加一个 AI 的日历，不是多时区 SaaS。
- **删除都是软删。** 行留在库里，只是不再出现。
- **没有多用户。** 一个 token 一本日历。
- **token 只挡源码分享。** `.gitignore` 挡住的只是「源码分享出去不带钥匙」。真要那一层安全得后端改成一人一把、能吊销的 key。
- **不做跨月的跨天事件。** 各月画各月的，一件跨月的事写成两条，只在渲染给 AI 看的时候拼成一条。
- **本 fork 不含 iOS 的 Vision 抠图贴纸。** 网页端照片走拍立得相框，不在浏览器里做主体抠图。

---

## 素材和许可

代码是 MIT，随便用。原作者版权声明见根目录 `LICENSE`。本 fork 的网页前端与相关修复同样以 MIT 发布。

- **贴纸**：沿用原作者那一套。一部分是脚本画的，一部分底图来自 Wikimedia Commons 的公有领域 / CC0 素材，逐张的出处在 `licenses/sources-*.md` 里。
- **字体**：霞鹜文楷（GB2312 子集）、Space Mono、Instrument Serif、Caveat，都是 OFL，许可证全文在 `licenses/`。
- **界面小图标**：来自 [Tabler Icons](https://github.com/tabler/tabler-icons) 和 [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)，都是 MIT，详见 `licenses/ICONS.txt`。

如果你也在做类似的东西，或者用它做了什么改动，原作者挺想看看的——请到原仓库找他。

---

## 本 fork 相对原仓库改了什么

- 用本地网页替代 iOS App：月/日视图、安排、便签、贴纸、拍立得、离开日视图时上传整页图
- 便签拖动和文字选择拆开，电脑和手机都能左右挪
- 贴纸可拖、可删、可旋转缩放
- 贴纸和便签颜色用原作者素材，不另换一套
- 补了网页侧给 AI 用的贴纸坐标 / 照片存储接口；MCP 六个动作和播种模块仍是原作者的
- 去掉 iOS 工程，避免把两套前端叠在一个仓库里

Agent 怎么接：优先 MCP（`list` / `see` / `create` / `update` / `delete` / `comment`），见上文「AI 能做什么」。每年都过的日子用播种模块，见「每年都过的日子」。
