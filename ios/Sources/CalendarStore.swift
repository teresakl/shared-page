import SwiftUI

// ============================================================
// CalendarStore.swift — 可变数据源。
// 设计包允许动的层：SampleData → 真实数据源（README 施工规则第 5 条）。
// 事件和便签搬到这里，其余常量（纪念日、贴纸归属天）仍留在 SampleData。
//
// 07-31 加了一层 month：现在显示的是哪个月由 store 说了算，
// 事件、便签、跨天安排全按月键（"2026-07" 这种）分桶存。
//
// 07-31 下午接上后端（CalendarAPI）：
//   · 事件和跨天安排现在是真数据，一进一个月就拉一次 GET /events?from=&to=
//   · 写操作一律「先改内存、再打网络、失败精确回滚」——用户点 save 当场就看得见，不等网络
//   · 本地一份缓存都不留。没网就是空的 + 副标题提示重试，不做离线队列、不落盘
//   · 样板数据退到 -sample 启动参数后面，平时一条都不注入
//   · 感叹号也接上了（GET /unseen + POST /unseen/seen），同样不落盘；
//     贴纸照片那一路还没做，继续本地
// ============================================================

/// 拉取状态。月视图副标题那行字全看它。
/// 它【不是】Equatable（failed 里裹着 Error），任何地方都不许写 .onChange(of: loadState)，编译过不去
enum LoadState {
    case idle, loading, loaded
    case failed(CalendarAPIError)
}

@Observable final class CalendarStore {
    /// 现在显示的是哪个月。月视图右上角 ◀ ▶ 点一下改的就是它，日视图、编辑器、贴纸落盘全跟着它走
    var month: CalMonth = .current

    /// 事件/便签/跨天安排按月分桶，桶的键是 "2026-07" 这种月键。
    /// 平时全是空的，内容由 load() 从后端拉回来填；只有加了 -sample 启动参数
    /// 才把设计稿那批样板注进 2026-07 那个桶（纯本地、一个请求都不发）
    private var eventsByMonth: [String: [Int: [CalEvent]]] =
        AppMode.isSample ? [CalMonth.sample.key: SampleData.events] : [:]
    private var notesByMonth: [String: [Int: [CalNote]]] =
        AppMode.isSample ? [CalMonth.sample.key: SampleData.notes] : [:]
    private var spansByMonth: [String: [CalSpan]] =
        AppMode.isSample
            ? [CalMonth.sample.key: SampleData.spans.sorted { $0.days.lowerBound < $1.days.lowerBound }]
            : [:]
    /// 生理期：每段一个闭区间日号。后端那条 event_type == "period" 的跨天事件换算过来的。
    /// 一个月可以有两段（跨月的那段已经在 materialize 里裁到本月内了）
    private var periodsByMonth: [String: [ClosedRange<Int>]] =
        AppMode.isSample ? [CalMonth.sample.key: [SampleData.periodDays]] : [:]

    // —— 网络那一摊 ————————————————————————————
    /// 当前这一屏的拉取状态。副标题那行字唯一的依据
    private(set) var loadState: LoadState = .idle

    /// 已经拉过一次的月份。翻回来时只是悄悄对一遍，副标题不再闪 syncing…
    private var loadedMonths: Set<String> = []

    /// 只增不减的流水号。翻月翻得快的时候会有好几个请求在飞、回来顺序不保证，
    /// 回调里对一下这个号，晚发出的才能落地，早发出的一律丢掉
    private var loadSeq: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    /// POST 还在飞的那几条临时 id（local_ 开头）
    private var creating: Set<String> = []
    private enum PostCreate { case patch, delete }
    /// POST 还没回来的那几百毫秒里用户又改了/删了 —— 先记一格，等拿到服务端 id 再补一刀。
    /// 一个临时 id 只留一格，后来的盖前面的。这【不是】离线队列，只活这一个 session
    private var afterCreate: [String: PostCreate] = [:]

    /// 便签那边同一套：POST 还在飞的临时 id、飞行期间的补刀、改字的防抖流水号
    private var creatingNotes: Set<String> = []
    private var afterCreateNote: [String: PostCreate] = [:]
    private var noteTextSeq: [String: UInt64] = [:]

    /// 当前月的跨天安排。按日号索引没意义（一条要出现在好几格里），一条数组按起始日排
    var spans: [CalSpan] { spansByMonth[month.key] ?? [] }

    func events(on day: Int) -> [CalEvent] { eventsByMonth[month.key]?[day] ?? [] }
    func notes(on day: Int)  -> [CalNote]  { notesByMonth[month.key]?[day] ?? [] }

    // —— 指定月份的读口（阶段五整页渲染用）————————————
    // 渲染的可能不是眼前这个月：用户在 8 月改完东西翻去 9 月才退后台，
    // 传上去的必须还是 8 月那几页。只读，不动现有单参数那组
    func events(in m: CalMonth, on day: Int) -> [CalEvent] { eventsByMonth[m.key]?[day] ?? [] }
    func notes(in m: CalMonth, on day: Int)  -> [CalNote]  { notesByMonth[m.key]?[day] ?? [] }
    func spans(in m: CalMonth, covering day: Int) -> [CalSpan] {
        (spansByMonth[m.key] ?? []).filter { $0.covers(day) }
    }

    // —— 阶段五：哪天动过要重新渲染上传 ————————————————
    /// 每个写操作完成本地改动后敲一下。真正的渲染和上传在 PageSync 里，
    /// 时机是退回月视图 / 切后台，这里只记一笔
    private func pageDirty(_ day: Int) { PageSync.shared.markDirty(month.dayKey(day)) }
    private func pageDirty(days: ClosedRange<Int>) { days.forEach(pageDirty) }

    /// 这天在不在生理期里，在的话整段是哪几天（首尾要画圆角，中间是平的）
    func periodRange(covering day: Int) -> ClosedRange<Int>? {
        periodsByMonth[month.key]?.first { $0.contains(day) }
    }

    // —— 爱心章：这天是不是特殊日子 ————————————————
    /// 纪念日、生日、约定之夜这一类。原来是写死的 anniversaryDays = [25]，
    /// 现在谁盖章由事件自己的 event_type 说了算，接后端时直接就对上了
    func isStampDay(_ day: Int) -> Bool {
        events(on: day).contains { $0.isSpecialDay }
    }

    // —— 感叹号：AI 侧改过、用户还没看的日子 ————————————
    /// 键是 "2026-08-25"。这一份完全跟着服务端走（consumer=kitty 的未读收据），
    /// 每次 load 顺手拉一遍全量灌进来，本地一个字都不落盘。
    /// -sample 模式一个请求都不发，只留设计稿里 7/25 那颗样板种子
    private(set) var unseenDays: Set<String> =
        AppMode.isSample ? [CalMonth.sample.dayKey(25)] : []

    /// 这次启动里已经标过已读的日子 → 记下标那一刻的 loadSeq。
    /// 拉取和标已读会撞车：用户刚点进 8/25，同一秒早就飞出去的那发 GET 还带着 8/25 回来，
    /// 落地就把感叹号又点亮了。只有比记下的号更晚发出去的那次拉取，才有资格重新点亮这一天
    private var seenAtSeq: [String: UInt64] = [:]

    func hasUnseen(_ day: Int) -> Bool { unseenDays.contains(month.dayKey(day)) }

    /// 点进某一天 = 看过了：先改内存（感叹号当场消失），再打后端。
    /// 失败【不回滚】—— 用户确实已经看过了，这个事实不该被一次网络抖动推翻。
    /// 代价只是下一次拉取会把这天再带回来一次，别自作主张加回滚
    func markSeen(_ day: Int) {
        let key = month.dayKey(day)
        unseenDays.remove(key)
        // 样板模式只在本地演一遍：那颗 7/25 的感叹号点进去照样该灭，
        // 但它压根不该发请求。08-02 这里原来是整个方法直接 return，
        // 结果样板那颗点了不消失，比接后端之前还退步了
        guard !AppMode.isSample else { return }
        // 本地集合里有没有这一天都得打这一发：冷启动直接落在日视图那种情形
        // （-openDay 或者从通知点进来），未读还没拉回来、本地是空的，
        // 但服务端那条收据照样得销掉，不然退出去再进来它又亮了
        guard seenAtSeq[key] == nil else { return }   // 一天一发，横划周条不至于连打七发
        seenAtSeq[key] = loadSeq
        Task { [weak self] in
            do {
                try await CalendarAPI.shared.markSeen(day: key)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // 销账成功。往后只有比现在更晚发出去的拉取说了算
                    self.seenAtSeq[key] = self.loadSeq
                }
            } catch {
                // 打不动就算了，界面不动。松开这个记号，下一次拉取还能把这天带回来
                await MainActor.run { [weak self] in self?.seenAtSeq[key] = nil }
            }
        }
    }

    /// AI 侧在某天留了东西。本地造数据用得上，留着，但不再落盘
    func markUnseen(_ day: Int) {
        unseenDays.insert(month.dayKey(day))
    }

    /// 拉回全量未读时整份换掉
    func replaceUnseen(_ keys: Set<String>) {
        unseenDays = keys
    }

    // ============================================================
    // 拉数据
    // ============================================================

    /// 月视图副标题那行字。三种状态三句话，MonthView 那边一个字面量都不留
    var subtitle: String {
        switch loadState {
        case .loading: return "syncing…"
        case .failed:  return "couldn't load · tap to retry"
        default:       return "tap a day to open it"
        }
    }

    /// 只有失败那一下副标题才点得动
    var canRetry: Bool {
        if case .failed = loadState { return true }
        return false
    }

    /// 点副标题那行字。不是失败状态就什么都不做，正常和加载中点它一点动静都没有
    func retry() {
        guard canRetry else { return }
        load(month, force: true)
    }

    /// 拉一个月：GET /events?from=本月1号&to=次月1号（半开区间，边界那条不会重复画）。
    /// 自带防串，只有最后发出去的那一次能落地
    func load(_ m: CalMonth, force: Bool = false) {
        guard !AppMode.isSample else { loadState = .loaded; return }
        loadTask?.cancel()
        loadSeq &+= 1
        let seq = loadSeq
        let mk = m.key
        // 这个月拉过一次了就不再闪 syncing…，翻回来只是悄悄对一遍，副标题不跳
        if !loadedMonths.contains(mk) || force { loadState = .loading }
        loadTask = Task { [weak self] in
            do {
                // 事件和便签两条请求并发发，谁先回都行，一起等
                async let eventsTask = CalendarAPI.shared.list(from: m.firstDate, to: m.next.firstDate)
                async let notesTask = CalendarAPI.shared.listNotes(
                    fromDay: m.dayKey(1), toDay: m.next.dayKey(1))
                // 未读单独一路，自己把错误吃掉：它挂了最多这一屏没有感叹号，事件和便签照常落地。
                // 并进下面那个 try 元组的话，后端一个 500 就能把整屏日历一起黑成 couldn't load
                async let unseenTask: [String]? = try? await CalendarAPI.shared.listUnseen()
                let (dtos, noteDtos) = try await (eventsTask, notesTask)
                let unseen = await unseenTask
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.applyLoaded(dtos, notes: noteDtos, unseen: unseen,
                                      month: m, mk: mk, seq: seq)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in self?.applyLoadFailure(error, seq: seq) }
            }
        }
    }

    @MainActor private func applyLoaded(_ dtos: [EventDTO], notes noteDtos: [NoteDTO],
                                        unseen: [String]?, month m: CalMonth,
                                        mk: String, seq: UInt64) {
        guard seq == loadSeq else { return }        // 迟到的结果，直接丢
        let p = CalMap.materialize(dtos, month: m)
        var events = p.events
        // 还在飞的 local_ 那几条留住，别被整月替换冲掉（不然 POST 回来找不到人换 id）
        for (day, list) in eventsByMonth[mk] ?? [:] {
            let inflight = list.filter { $0.isLocalOnly }
            if !inflight.isEmpty { events[day, default: []].append(contentsOf: inflight) }
        }
        eventsByMonth[mk] = events
        spansByMonth[mk] = p.spans + (spansByMonth[mk]?.filter { $0.isLocalOnly } ?? [])
        periodsByMonth[mk] = p.periods
        // 便签整月替换，同样保住还在飞的那几条 local_
        var fresh = CalMap.notesByDay(noteDtos, month: m)
        for (day, list) in notesByMonth[mk] ?? [:] {
            let inflight = list.filter { $0.isLocalOnly }
            if !inflight.isEmpty { fresh[day, default: []].append(contentsOf: inflight) }
        }
        notesByMonth[mk] = fresh
        // 感叹号：服务端那份是全局的、不分月，所以整份换掉。
        // 拉挂了（unseen 为 nil）就保持原样不动，别把已经画出来的感叹号抹平
        if let unseen {
            var next: Set<String> = []
            for key in unseen {
                // 这一发比「用户点进那天」还早发出去的话，带回来的未读是旧的，不算数
                if let at = seenAtSeq[key], seq <= at { continue }
                // 服务端仍然说它未读（AI 侧又在那天动了新东西），这天重新归零，
                // 下次用户点进去要再销一次账
                seenAtSeq[key] = nil
                next.insert(key)
            }
            replaceUnseen(next)
        }
        loadedMonths.insert(mk)
        sortSpans(mk)                                // 塞回去的 local_ 那几条也得归位
        for day in eventsByMonth[mk]?.keys ?? [:].keys { sortEvents(mk, day) }
        if mk == month.key { loadState = .loaded }   // 状态只反映当前这一屏
    }

    @MainActor private func applyLoadFailure(_ error: Error, seq: UInt64) {
        guard seq == loadSeq else { return }
        loadState = .failed(error as? CalendarAPIError ?? .offline)
    }

    /// 写操作失败的统一落点。只置状态，本地怎么退回去各家自己管
    @MainActor private func markFailed(_ error: Error) {
        loadState = .failed(error as? CalendarAPIError ?? .offline)
    }

    // ============================================================
    // 跨天安排
    // ============================================================

    func spans(covering day: Int) -> [CalSpan] { spans.filter { $0.covers(day) } }

    func addSpan(_ s: CalSpan) {
        let mk = month.key
        let m = month
        spansByMonth[mk, default: []].append(s)
        sortSpans(mk)
        pageDirty(days: s.days)
        guard !AppMode.isSample else { return }

        let temp = s.id
        creating.insert(temp)
        let body = CalMap.createBody(s, month: m)
        Task { [weak self] in
            do {
                let dto = try await CalendarAPI.shared.create(body)
                await MainActor.run { [weak self] in
                    self?.finishCreateSpan(temp: temp, dto: dto, mk: mk, month: m)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackCreateSpan(temp: temp, mk: mk, error: error)
                }
            }
        }
    }

    /// id 换成 var 了，但改的时候仍然只动字段不重建对象 —— 重建会让 ForEach 重播入场动画
    func updateSpan(_ s: CalSpan, title: String, start: Int, end: Int) {
        let mk = month.key
        let m = month
        guard let i = spansByMonth[mk]?.firstIndex(where: { $0.id == s.id }) else { return }
        // 回滚只退这一条。原来这里拍的是整份数组快照，网络挂了会把这期间别的改动一起推翻 ——
        // 最难受的是把另一条刚换好的服务端 id 打回 local_，那条从此重复、改不动也删不掉
        let before = spansByMonth[mk]![i]
        spansByMonth[mk]![i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        spansByMonth[mk]![i].startDay = min(start, end)
        spansByMonth[mk]![i].endDay = max(start, end)
        // 用户把某一端挪离月首/月末，等于亲手放弃了那一端月外那半截（日号选择器里用户也只能选本月的），
        // 锚点就此作废；没挪过的那一端仍然按服务端原来那个时刻写回去
        let r = spansByMonth[mk]![i].days
        spansByMonth[mk]![i].clip = clipKeeping(before.clip,
                                                head: r.lowerBound == 1,
                                                tail: r.upperBound == m.daysInMonth)
        let after = spansByMonth[mk]![i]            // 排序会打乱下标，先把这条取出来
        sortSpans(mk)
        pageDirty(days: before.days)                // 缩掉的那几天也变了样，两头都记
        pageDirty(days: after.days)
        guard !AppMode.isSample else { return }

        // POST 还在飞，id 还是 local_xxx，这时候 PATCH 过去必然 404。只记一格，等真 id 回来再补
        if creating.contains(after.id) { afterCreate[after.id] = .patch; return }
        patchSpan(after, mk: mk, month: m, rollbackTo: before)
    }

    func deleteSpan(_ s: CalSpan) {
        let mk = month.key
        // 整条删就是整条删：这条要是在本月之外还有半截，那半截也一起收走 ——
        // 用户删的是「这件事」，不是「这件事在八月的那几天」
        let removed = spansByMonth[mk]?.first { $0.id == s.id } ?? s
        spansByMonth[mk]?.removeAll { $0.id == s.id }
        pageDirty(days: removed.days)
        guard !AppMode.isSample else { return }

        // 还在飞的时候删：本地先没掉，等 POST 回来拿到真 id 再补一刀 DELETE。
        // 直接发的话后端 404，而那条 POST 一会儿照样会成功，服务端会留下一条用户再也看不见的孤儿
        if creating.contains(s.id) { afterCreate[s.id] = .delete; return }
        deleteSpanRemote(removed, mk: mk)
    }

    /// 日视图上的「去掉这天」：从这条里挖掉某一天，而不是整条删。
    /// 挖头挖尾 → 起止往里缩一天（一发 PATCH）；挖中间 → 裂成同名的两段（一 POST 一 PATCH）；
    /// 本来只有一天 → 整条没了（一发 DELETE）。
    /// 挖的这天正好压在「本月之外还有半截」的那一端时多走一步：先把月外那半截存成独立的一条，
    /// 剩下的才按上面三种走 —— 那几天用户在这一屏上根本看不见，不能让这一刀顺手削掉
    func removeDay(_ day: Int, from s: CalSpan) {
        let mk = month.key
        let m = month
        guard let i = spansByMonth[mk]?.firstIndex(where: { $0.id == s.id }) else { return }
        let before = spansByMonth[mk]![i]
        let r = before.days
        guard r.contains(day) else { return }
        // 挖的这天正好压在被裁过的那一端：月外那半截得先单独存成一条，
        // 不然这一刀会把用户根本看不见的那几天一起削掉（nil = 这一端没被裁过，走老路）
        let hidden = CalMap.hiddenHalfBody(before, removing: day, month: m)
        pageDirty(days: before.days)                // 挖掉一天，整条色带的形状都变了

        // 只有一天：等同整条删
        if r.count == 1 {
            spansByMonth[mk]!.remove(at: i)
            sortSpans(mk)
            guard !AppMode.isSample else { return }
            if creating.contains(s.id) { afterCreate[s.id] = .delete; return }
            // 本月就露这一天、月外还有半截：不能整条删，改成把它缩成月外那半截
            if let hidden {
                sendSpanPatch(id: s.id, body: hidden, mk: mk, restore: before, reinsertIfGone: true)
            } else {
                deleteSpanRemote(before, mk: mk)
            }
            return
        }

        // 挖头挖尾：往里缩一天，对后端就是改一下起止
        if day == r.lowerBound || day == r.upperBound {
            if day == r.lowerBound {
                spansByMonth[mk]![i].startDay = r.lowerBound + 1
                spansByMonth[mk]![i].endDay = r.upperBound
                // 头上那半截马上要另起一条了，这条的头锚点就此作废
                spansByMonth[mk]![i].clip = clipKeeping(before.clip, head: false, tail: true)
            } else {
                spansByMonth[mk]![i].startDay = r.lowerBound
                spansByMonth[mk]![i].endDay = r.upperBound - 1
                spansByMonth[mk]![i].clip = clipKeeping(before.clip, head: true, tail: false)
            }
            let after = spansByMonth[mk]![i]
            sortSpans(mk)
            guard !AppMode.isSample else { return }
            if creating.contains(after.id) { afterCreate[after.id] = .patch; return }
            if let hidden {
                splitOffHidden(hidden, then: after, mk: mk, month: m, restore: before)
            } else {
                patchSpan(after, mk: mk, month: m, rollbackTo: before)
            }
            return
        }

        // 挖中间：原来那条截到 day-1，后半段另起一条同名的。
        // 月外那两半各归各家：头上那半截跟着前半段，尾巴那半截跟着后半段
        spansByMonth[mk]![i].startDay = r.lowerBound
        spansByMonth[mk]![i].endDay = day - 1
        spansByMonth[mk]![i].clip = clipKeeping(before.clip, head: true, tail: false)
        let tail = CalSpan(author: s.author, title: s.title,
                           startDay: day + 1, endDay: r.upperBound,
                           clip: clipKeeping(before.clip, head: false, tail: true))
        spansByMonth[mk]!.append(tail)
        let head = spansByMonth[mk]![i]             // 排序前先取出来，排完下标就不是它了
        sortSpans(mk)
        guard !AppMode.isSample else { return }

        // 顺序必须是先 POST 后半段、再 PATCH 前半段：
        //   POST 挂了 → 服务端一个字没变，本地把后半段撤掉、前半段退回原样，干干净净
        //   POST 成了 PATCH 挂了 → 服务端多出一条、原来那条没截短，置失败之后补一发整月重拉，
        //                          让用户看到服务端的真相
        // 反过来先 PATCH 的话，第一刀成第二刀败，用户那条跨天安排会当场少半截且服务端也少半截，更糟
        let temp = tail.id
        creating.insert(temp)
        let tailBody = CalMap.createBody(tail, month: m)
        // 前半段自己还在飞的话，截短这一刀交给它的 finishCreateSpan 去补
        let headInFlight = creating.contains(head.id)
        if headInFlight { afterCreate[head.id] = .patch }
        let headID = head.id
        let headBody = CalMap.patchBody(head, month: m)

        Task { [weak self] in
            let dto: EventDTO
            do {
                dto = try await CalendarAPI.shared.create(tailBody)
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackSplit(temp: temp, headBefore: before, headInFlight: headInFlight,
                                        mk: mk, error: error)
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.finishCreateSpan(temp: temp, dto: dto, mk: mk, month: m)
            }
            guard !headInFlight else { return }
            do {
                _ = try await CalendarAPI.shared.update(id: headID, headBody)
            } catch {
                // 本地不退回去 —— 退了的话服务端那条刚建出来的后半段就没人认领了。
                // 置失败之后重拉整月，服务端是什么样用户就看到什么样
                await MainActor.run { [weak self] in
                    self?.markFailed(error)
                    self?.load(m, force: true)
                }
            }
        }
    }

    /// 起始日在前；同一天开始的，长的排前面，色带堆叠顺序才不会跳。
    /// 不给月键就是排当前这个月（原来的用法）；拉数据回来的时候要指定，那时候用户可能已经翻月了
    private func sortSpans(_ mk: String? = nil) {
        spansByMonth[mk ?? month.key]?.sort {
            $0.days.lowerBound == $1.days.lowerBound
                ? $0.length > $1.length
                : $0.days.lowerBound < $1.days.lowerBound
        }
    }

    // —— 跨天安排的网络那几刀 ————————————————————

    private func patchSpan(_ s: CalSpan, mk: String, month m: CalMonth, rollbackTo before: CalSpan) {
        sendSpanPatch(id: s.id, body: CalMap.patchBody(s, month: m), mk: mk, restore: before)
    }

    /// 发一发 PATCH，挂了就把这一条退回改之前的样子。
    /// reinsertIfGone = 这一刀本来就把它从桶里拿掉了（缩成月外那半截那种），失败要整条放回去
    private func sendSpanPatch(id: String, body: EventWriteDTO, mk: String,
                               restore before: CalSpan, reinsertIfGone: Bool = false) {
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.update(id: id, body)
            } catch {
                await MainActor.run { [weak self] in
                    if reinsertIfGone { self?.reinsertSpan(before, mk: mk, error: error) }
                    else { self?.restoreSpan(before, mk: mk, error: error) }
                }
            }
        }
    }

    private func deleteSpanRemote(_ removed: CalSpan, mk: String) {
        let id = removed.id
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.delete(id: id)
            } catch {
                await MainActor.run { [weak self] in self?.reinsertSpan(removed, mk: mk, error: error) }
            }
        }
    }

    /// 「去掉这天」正好挖在被裁过的那一端：先 POST 把月外那半截存成独立的一条，
    /// 成了再 PATCH 让原来这条缩进本月。顺序跟「挖中间」一个道理 ——
    /// POST 挂了服务端一个字没变，本地退回去就干净；
    /// POST 成了 PATCH 挂了，服务端多一条、原来那条没缩，置失败之后整月重拉，用户看到的就是服务端的真相
    private func splitOffHidden(_ hidden: EventWriteDTO, then after: CalSpan,
                                mk: String, month m: CalMonth, restore before: CalSpan) {
        let id = after.id
        let body = CalMap.patchBody(after, month: m)
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.create(hidden)
            } catch {
                await MainActor.run { [weak self] in self?.restoreSpan(before, mk: mk, error: error) }
                return
            }
            do {
                _ = try await CalendarAPI.shared.update(id: id, body)
            } catch {
                await MainActor.run { [weak self] in
                    self?.markFailed(error)
                    self?.load(m, force: true)
                }
            }
        }
    }

    /// 精确回滚一条：按 id 找到它，换回改之前那份。
    /// 【别】改回整份数组快照 —— 那会把这期间别的改动一起推翻，
    /// 最狠的一种是把另一条刚换好的服务端 id 打回 local_，那条从此重复、改不动也删不掉。
    /// 找不到（这几百毫秒里它换了 id 或者被拿掉了）就什么都不做，下一次重拉自然对齐
    @MainActor private func restoreSpan(_ before: CalSpan, mk: String, error: Error) {
        if let i = spansByMonth[mk]?.firstIndex(where: { $0.id == before.id }) {
            spansByMonth[mk]![i] = before
            sortSpans(mk)
        }
        markFailed(error)
    }

    /// 删挂了：把刚拿掉那条放回去。桶里已经有同 id 的（比如中间有一次 GET 落地）就不重复放
    @MainActor private func reinsertSpan(_ removed: CalSpan, mk: String, error: Error) {
        if spansByMonth[mk]?.contains(where: { $0.id == removed.id }) != true {
            spansByMonth[mk, default: []].append(removed)
            sortSpans(mk)
        }
        markFailed(error)
    }

    /// 拆一条被裁过的跨天安排时用：把不再属于这一半的那个锚点去掉。
    /// 两个都不留就整个是 nil，回到「本月之内、老老实实按日号写回去」那条路
    private func clipKeeping(_ c: CalSpanClip?, head keepHead: Bool, tail keepTail: Bool) -> CalSpanClip? {
        guard let c else { return nil }
        let k = CalSpanClip(headStart: keepHead ? c.headStart : nil,
                            tailEnd: keepTail ? c.tailEnd : nil)
        return k.isEmpty ? nil : k
    }

    @MainActor private func finishCreateSpan(temp: String, dto: EventDTO, mk: String, month m: CalMonth) {
        creating.remove(temp)
        let pending = afterCreate.removeValue(forKey: temp)

        // 在飞的这几百毫秒里用户把它删了：本地早就没了，只补一刀把服务端那条也收走。
        // 这中间要是有一次 GET 落地，服务端那条已经被塞进桶里了，顺手撤掉，不然屏幕上挂个鬼影
        if let p = pending, case .delete = p {
            spansByMonth[mk]?.removeAll { $0.id == dto.id }
            deleteRemote(dto.id)
            return
        }

        guard let i = spansByMonth[mk]?.firstIndex(where: { $0.id == temp }) else { return }
        // 这几百毫秒里有一次 GET 落地，服务端那条已经进桶了：把本地这条的内容盖上去
        // （用户可能在这中间改过），再把本地这条撤掉。两条都叫 cal_xxx 的话 ForEach 会踩重复 id
        if let j = spansByMonth[mk]!.firstIndex(where: { $0.id == dto.id }) {
            var mine = spansByMonth[mk]![i]
            mine.id = dto.id
            spansByMonth[mk]![j] = mine
            spansByMonth[mk]!.remove(at: i)
            sortSpans(mk)
        } else {
            spansByMonth[mk]![i].id = dto.id        // 就地换 id，不重建对象
        }

        // 在飞的时候用户又改过（改名、改起止、或者被挖掉一天）—— 拿桶里现在这条补一发 PATCH
        if let p = pending, case .patch = p,
           let k = spansByMonth[mk]?.firstIndex(where: { $0.id == dto.id }) {
            patchRemote(id: dto.id, body: CalMap.patchBody(spansByMonth[mk]![k], month: m))
        }
    }

    @MainActor private func rollbackCreateSpan(temp: String, mk: String, error: Error) {
        creating.remove(temp)
        afterCreate.removeValue(forKey: temp)
        spansByMonth[mk]?.removeAll { $0.id == temp }
        markFailed(error)
    }

    /// 挖中间那一刀的第一步（POST 后半段）就挂了：服务端一个字没变，
    /// 本地把后半段撤掉、前半段退回截短之前的样子（只动这两条，别碰同月别的）
    @MainActor private func rollbackSplit(temp: String, headBefore: CalSpan, headInFlight: Bool,
                                          mk: String, error: Error) {
        creating.remove(temp)
        afterCreate.removeValue(forKey: temp)
        if headInFlight { afterCreate.removeValue(forKey: headBefore.id) }
        spansByMonth[mk]?.removeAll { $0.id == temp }
        restoreSpan(headBefore, mk: mk, error: error)
    }

    // ============================================================
    // 事件
    // ============================================================

    /// 按开始时间排好序再放进去，时间轴才不会串。
    /// 先插桶（用户点 save 当场就看得见，不等网络），再发 POST；回来把临时 id 换成服务端那个
    func add(_ event: CalEvent, on day: Int) {
        let mk = month.key
        let m = month
        eventsByMonth[mk, default: [:]][day, default: []].append(event)
        sortEvents(mk, day)
        pageDirty(day)
        guard !AppMode.isSample else { return }

        let temp = event.id
        creating.insert(temp)
        let body = CalMap.createBody(event, on: day, month: m)
        Task { [weak self] in
            do {
                let dto = try await CalendarAPI.shared.create(body)
                await MainActor.run { [weak self] in
                    self?.finishCreate(temp: temp, dto: dto, mk: mk, day: day, month: m)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackCreate(temp: temp, mk: mk, day: day, error: error)
                }
            }
        }
    }

    /// 改一条已有的。id 换成 var 了，但仍然只动字段不重建对象 ——
    /// 重建会让 ForEach 把这一行当成删一行插一行，重播入场动画。
    /// 全天事件不动时间，只改名。
    func update(_ event: CalEvent, on day: Int, title: String,
                start: Date, end: Date, allDay: Bool) {
        let mk = month.key
        let m = month
        guard let i = eventsByMonth[mk]?[day]?.firstIndex(where: { $0.id == event.id }) else { return }
        let before = eventsByMonth[mk]![day]![i]    // 网络挂了要整条换回来
        eventsByMonth[mk]![day]![i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        eventsByMonth[mk]![day]![i].isAllDay = allDay
        if allDay {
            eventsByMonth[mk]![day]![i].startHour = 0
            eventsByMonth[mk]![day]![i].startMinute = 0
            eventsByMonth[mk]![day]![i].durationMinutes = 0
        } else {
            let (h, m2, dur) = Self.span(start: start, end: end)
            eventsByMonth[mk]![day]![i].startHour = h
            eventsByMonth[mk]![day]![i].startMinute = m2
            eventsByMonth[mk]![day]![i].durationMinutes = dur
        }
        let after = eventsByMonth[mk]![day]![i]     // 排序会打乱下标，先取出来
        sortEvents(mk, day)
        pageDirty(day)
        guard !AppMode.isSample else { return }

        // POST 还在飞，id 还是 local_xxx，PATCH 过去必然 404。只记一格，等真 id 回来再补
        if creating.contains(after.id) { afterCreate[after.id] = .patch; return }

        let id = after.id
        let body = CalMap.patchBody(after, on: day, month: m)
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.update(id: id, body)
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackUpdate(before, mk: mk, day: day, error: error)
                }
            }
        }
    }

    func delete(_ event: CalEvent, on day: Int) {
        let mk = month.key
        let removed = eventsByMonth[mk]?[day]?.first { $0.id == event.id }
        eventsByMonth[mk]?[day]?.removeAll { $0.id == event.id }
        if eventsByMonth[mk]?[day]?.isEmpty == true { eventsByMonth[mk]![day] = nil }
        // 挂在这条日程上的便签留着，只是解开关联，退回「只关于这一天」。
        // 顺手记下解开了哪几张，网络挂了要原样接回去
        var unlinked: [String] = []
        for i in notesByMonth[mk]?[day]?.indices ?? (0..<0)
        where notesByMonth[mk]![day]![i].linkedEventID == event.id {
            unlinked.append(notesByMonth[mk]![day]![i].id)
            notesByMonth[mk]![day]![i].linkedEventID = nil
        }
        pageDirty(day)
        guard !AppMode.isSample, let removed else { return }

        // 还在飞的时候删：本地先没掉，等 POST 回来拿到真 id 再补一刀。
        // 直接发的话后端 404，而那条 POST 照样会成功，服务端会留下一条用户再也看不见、也删不掉的孤儿
        if creating.contains(event.id) { afterCreate[event.id] = .delete; return }

        let id = event.id
        let unlinkedIDs = unlinked     // var 不能被带进并发闭包，先定死一份再交出去
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.delete(id: id)
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackDelete(removed, mk: mk, day: day, unlinked: unlinkedIDs, error: error)
                }
            }
        }
    }

    /// 按开始时间排一遍，时间轴才不会串
    private func sortEvents(_ mk: String, _ day: Int) {
        eventsByMonth[mk]?[day]?.sort {
            ($0.startHour * 60 + $0.startMinute) < ($1.startHour * 60 + $1.startMinute)
        }
    }

    // —— 事件的网络回调 ————————————————————————

    @MainActor private func finishCreate(temp: String, dto: EventDTO,
                                         mk: String, day: Int, month m: CalMonth) {
        creating.remove(temp)
        let pending = afterCreate.removeValue(forKey: temp)

        // 在飞的这几百毫秒里用户把这条删了：本地早就没了，只补一刀把服务端那条也收走。
        // 这中间要是有一次 GET 落地，服务端那条已经被塞进桶里了，顺手撤掉，不然屏幕上挂个鬼影
        if let p = pending, case .delete = p {
            eventsByMonth[mk]?[day]?.removeAll { $0.id == dto.id }
            if eventsByMonth[mk]?[day]?.isEmpty == true { eventsByMonth[mk]![day] = nil }
            deleteRemote(dto.id)
            return
        }

        guard let i = eventsByMonth[mk]?[day]?.firstIndex(where: { $0.id == temp }) else { return }
        // 这几百毫秒里有一次 GET 落地，服务端那条已经进桶了：把本地这条的内容盖上去
        // （用户可能在这中间改过），再把本地这条撤掉。两条都叫 cal_xxx 的话 ForEach 会踩重复 id
        if let j = eventsByMonth[mk]![day]!.firstIndex(where: { $0.id == dto.id }) {
            var mine = eventsByMonth[mk]![day]![i]
            mine.id = dto.id
            eventsByMonth[mk]![day]![j] = mine
            eventsByMonth[mk]![day]!.remove(at: i)
            sortEvents(mk, day)
        } else {
            eventsByMonth[mk]![day]![i].id = dto.id // 就地换 id，不重建对象
        }
        // 换 id 的同一个动作里必须扫一遍便签，不然那张纸角上的「↳ 事件名」会无声消失
        for j in notesByMonth[mk]?[day]?.indices ?? (0..<0)
        where notesByMonth[mk]![day]![j].linkedEventID == temp {
            notesByMonth[mk]![day]![j].linkedEventID = dto.id
        }

        // 在飞的时候用户又改过 —— 拿桶里现在这条补一发 PATCH
        if let p = pending, case .patch = p,
           let k = eventsByMonth[mk]?[day]?.firstIndex(where: { $0.id == dto.id }) {
            patchRemote(id: dto.id, body: CalMap.patchBody(eventsByMonth[mk]![day]![k], on: day, month: m))
        }
    }

    @MainActor private func rollbackCreate(temp: String, mk: String, day: Int, error: Error) {
        creating.remove(temp)
        afterCreate.removeValue(forKey: temp)
        eventsByMonth[mk]?[day]?.removeAll { $0.id == temp }
        if eventsByMonth[mk]?[day]?.isEmpty == true { eventsByMonth[mk]![day] = nil }
        // 这条根本没建成，挂在它上面的便签也得解开，不然纸角上指着一条不存在的事件
        for j in notesByMonth[mk]?[day]?.indices ?? (0..<0)
        where notesByMonth[mk]![day]![j].linkedEventID == temp {
            notesByMonth[mk]![day]![j].linkedEventID = nil
        }
        markFailed(error)
    }

    @MainActor private func rollbackUpdate(_ before: CalEvent, mk: String, day: Int, error: Error) {
        if let i = eventsByMonth[mk]?[day]?.firstIndex(where: { $0.id == before.id }) {
            eventsByMonth[mk]![day]![i] = before
            sortEvents(mk, day)
        }
        markFailed(error)
    }

    @MainActor private func rollbackDelete(_ event: CalEvent, mk: String, day: Int,
                                           unlinked: [String], error: Error) {
        eventsByMonth[mk, default: [:]][day, default: []].append(event)
        sortEvents(mk, day)
        for j in notesByMonth[mk]?[day]?.indices ?? (0..<0)
        where unlinked.contains(notesByMonth[mk]![day]![j].id) {
            notesByMonth[mk]![day]![j].linkedEventID = event.id
        }
        markFailed(error)
    }

    // —— 补发的那一刀：本地早就是最终形态了，结果只影响失败提示 ——————

    private func deleteRemote(_ id: String) {
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.delete(id: id)
            } catch {
                await MainActor.run { [weak self] in self?.markFailed(error) }
            }
        }
    }

    private func patchRemote(id: String, body: EventWriteDTO) {
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.update(id: id, body)
            } catch {
                await MainActor.run { [weak self] in self?.markFailed(error) }
            }
        }
    }

    // ============================================================
    // 便签
    //
    // 跟事件同一套规矩：先改内存让用户当场看见，再打网络，失败精确回滚。
    // 唯一不同的是改字 —— 用户每敲一个字就调一次 setNoteText，
    // 那条不能一个字一发请求，攒 0.6 秒只发最后一次
    // ============================================================

    func addNote(_ note: CalNote, on day: Int) {
        let mk = month.key
        var n = note
        n.anchorDate = month.dayKey(day)
        notesByMonth[mk, default: [:]][day, default: []].append(n)
        pageDirty(day)
        guard !AppMode.isSample else { return }
        // 空白的先只活在本地。后端那边写着「便签不能是空的」，空 body POST 上去回 400，
        // 前端一回滚就把用户刚撕下来的那张纸从屏幕上撤掉了 —— 用户根本来不及打字。
        // 等用户写了字、收笔的时候走 commitNote 再发第一次
        guard !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let temp = n.id
        creatingNotes.insert(temp)
        let body = CalMap.createBody(n, on: day, month: month)
        Task { [weak self] in
            do {
                let dto = try await CalendarAPI.shared.createNote(body)
                await MainActor.run { [weak self] in
                    self?.finishCreateNote(temp: temp, dto: dto, mk: mk, day: day)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackCreateNote(temp: temp, mk: mk, day: day, error: error)
                }
            }
        }
    }

    func deleteNote(_ note: CalNote, on day: Int) {
        let mk = month.key
        guard let removed = notesByMonth[mk]?[day]?.first(where: { $0.id == note.id }) else { return }
        notesByMonth[mk]?[day]?.removeAll { $0.id == note.id }
        if notesByMonth[mk]?[day]?.isEmpty == true { notesByMonth[mk]![day] = nil }
        noteTextSeq[note.id] = nil          // 还攒着没发的那次改字作废
        pageDirty(day)
        guard !AppMode.isSample else { return }
        if removed.isLocalOnly {
            // POST 还没回来就被撕了：记一格，等拿到服务端 id 再补一刀删。
            // 压根没发过的（空白纸）本地删掉就完了，服务器上根本没有它
            if creatingNotes.contains(removed.id) { afterCreateNote[removed.id] = .delete }
            return
        }
        let id = removed.id
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.deleteNote(id: id)
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackDeleteNote(removed, mk: mk, day: day, error: error)
                }
            }
        }
    }

    /// 拖到哪儿就落在哪儿；压在某条日程上就顺手把关联记下来
    func placeNote(_ note: CalNote, on day: Int, y: CGFloat, linkedTo eventID: String?) {
        let mk = month.key
        guard let i = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == note.id }) else { return }
        let before = notesByMonth[mk]![day]![i]
        notesByMonth[mk]![day]![i].y = y
        notesByMonth[mk]![day]![i].linkedEventID = eventID
        pageDirty(day)
        // 绑到一条还没上过后端的日程上时，服务端还不认识那个 local_ id，先只发位置；
        // 等那条事件的 POST 回来，finishCreate 会把 linkedEventID 换成真 id，那时候再补
        let sendable = (eventID.map { CalID.isLocal($0) } ?? false) ? nil : Optional(eventID)
        pushNote(notesByMonth[mk]![day]![i], before: before, mk: mk, day: day,
                 body: NoteWriteDTO(y: Double(y), eventID: sendable))
    }

    /// 便签是原地写的，每敲一个字就落一次内存。上行攒 0.6 秒只发最后一次
    func setNoteText(_ note: CalNote, on day: Int, text: String) {
        let mk = month.key
        guard let i = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == note.id }) else { return }
        let clean = NoteFit.truncate(text, author: notesByMonth[mk]![day]![i].author)
        notesByMonth[mk]![day]![i].text = clean
        pageDirty(day)
        guard !AppMode.isSample else { return }
        let id = notesByMonth[mk]![day]![i].id
        let token = (noteTextSeq[id] ?? 0) &+ 1
        noteTextSeq[id] = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { [weak self] in
                guard let self, self.noteTextSeq[id] == token else { return }   // 后面又敲了字，这次作废
                self.noteTextSeq[id] = nil
                guard let cur = self.notesByMonth[mk]?[day]?.first(where: { $0.id == id }) else { return }
                if cur.isLocalOnly {
                    // POST 还在飞：等它回来的时候桶里已经是最新的字了，createBody 那份是旧的，补一发。
                    // 压根还没发过（空白纸刚撕下来）：什么都不做，等用户收笔时 commitNote 发第一次 ——
                    // 打字过程中换 id 会把输入框当场作废，那就是「来不及打字」的那种情况
                    if self.creatingNotes.contains(id) { self.afterCreateNote[id] = .patch }
                    return
                }
                self.patchNoteRemote(id: id, body: NoteWriteDTO(body: cur.text))
            }
        }
    }

    /// 收笔。第一次把这张纸送上服务器 —— 打字全程都不发网络，
    /// 换 id 那一下才不会把用户正在打字的输入框弄没
    func commitNote(id: String, on day: Int) {
        let mk = month.key
        guard !AppMode.isSample,
              let n = notesByMonth[mk]?[day]?.first(where: { $0.id == id }),
              n.isLocalOnly,
              !creatingNotes.contains(id),
              !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        creatingNotes.insert(id)
        let body = CalMap.createBody(n, on: day, month: month)
        Task { [weak self] in
            do {
                let dto = try await CalendarAPI.shared.createNote(body)
                await MainActor.run { [weak self] in
                    self?.finishCreateNote(temp: id, dto: dto, mk: mk, day: day)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackCreateNote(temp: id, mk: mk, day: day, error: error)
                }
            }
        }
    }

    /// 双击 AI 侧的便签点赞。只点得到对方的，自己写的那些不挂这个手势
    func toggleLike(_ note: CalNote, on day: Int) {
        let mk = month.key
        guard let i = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == note.id }) else { return }
        let before = notesByMonth[mk]![day]![i]
        notesByMonth[mk]![day]![i].liked.toggle()
        pageDirty(day)                              // 红心也在页面上，点赞收赞都算动过
        let now = notesByMonth[mk]![day]![i]
        pushNote(now, before: before, mk: mk, day: day, body: NoteWriteDTO(liked: now.liked))
    }

    // —— 便签的网络那一摊 ————————————————————————

    /// 改一张已经上过后端的便签。还在飞的记一格等 POST 回来补
    private func pushNote(_ note: CalNote, before: CalNote, mk: String, day: Int,
                          body: NoteWriteDTO) {
        guard !AppMode.isSample else { return }
        if note.isLocalOnly {
            if creatingNotes.contains(note.id) { afterCreateNote[note.id] = .patch }
            return
        }
        let id = note.id
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.updateNote(id: id, body)
            } catch {
                await MainActor.run { [weak self] in
                    self?.rollbackNote(before, mk: mk, day: day, error: error)
                }
            }
        }
    }

    private func patchNoteRemote(id: String, body: NoteWriteDTO) {
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.updateNote(id: id, body)
            } catch {
                await MainActor.run { [weak self] in self?.markFailed(error) }
            }
        }
    }

    @MainActor private func finishCreateNote(temp: String, dto: NoteDTO, mk: String, day: Int) {
        creatingNotes.remove(temp)
        let pending = afterCreateNote.removeValue(forKey: temp)

        if let p = pending, case .delete = p {
            notesByMonth[mk]?[day]?.removeAll { $0.id == dto.id }
            if notesByMonth[mk]?[day]?.isEmpty == true { notesByMonth[mk]![day] = nil }
            deleteNoteRemote(dto.id)
            return
        }
        guard let i = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == temp }) else { return }
        // 这几百毫秒里有一次 GET 落地，服务端那条已经进桶了：内容以本地为准盖上去，再撤掉本地这条。
        // 两条都叫 cmt_xxx 的话 ForEach 会踩重复 id
        if let j = notesByMonth[mk]![day]!.firstIndex(where: { $0.id == dto.id }) {
            var mine = notesByMonth[mk]![day]![i]
            mine.id = dto.id
            notesByMonth[mk]![day]![j] = mine
            notesByMonth[mk]![day]!.remove(at: i)
        } else {
            notesByMonth[mk]![day]![i].id = dto.id
        }
        if let p = pending, case .patch = p,
           let k = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == dto.id }) {
            let n = notesByMonth[mk]![day]![k]
            let ev = (n.linkedEventID.map { CalID.isLocal($0) } ?? false) ? nil : Optional(n.linkedEventID)
            patchNoteRemote(id: dto.id, body: NoteWriteDTO(
                body: n.text, y: n.y.map { Double($0) }, liked: n.liked, eventID: ev))
        }
    }

    @MainActor private func rollbackCreateNote(temp: String, mk: String, day: Int, error: Error) {
        creatingNotes.remove(temp)
        afterCreateNote.removeValue(forKey: temp)
        noteTextSeq[temp] = nil
        notesByMonth[mk]?[day]?.removeAll { $0.id == temp }
        if notesByMonth[mk]?[day]?.isEmpty == true { notesByMonth[mk]![day] = nil }
        markFailed(error)
    }

    @MainActor private func rollbackNote(_ before: CalNote, mk: String, day: Int, error: Error) {
        if let i = notesByMonth[mk]?[day]?.firstIndex(where: { $0.id == before.id }) {
            notesByMonth[mk]![day]![i] = before
        }
        markFailed(error)
    }

    @MainActor private func rollbackDeleteNote(_ note: CalNote, mk: String, day: Int, error: Error) {
        notesByMonth[mk, default: [:]][day, default: []].append(note)
        markFailed(error)
    }

    private func deleteNoteRemote(_ id: String) {
        Task { [weak self] in
            do {
                _ = try await CalendarAPI.shared.deleteNote(id: id)
            } catch {
                await MainActor.run { [weak self] in self?.markFailed(error) }
            }
        }
    }

    // ============================================================
    // 时间小工具
    // ============================================================

    /// 现在几点，写成便签上那行时间戳。
    /// 时区跟 CalMonth 一样钉死 Asia/Shanghai：日历顶上写的是哪天，
    /// 新撕的便签就得打哪天。跟着设备时区走的话，人在国外时两边会差一整天
    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = CalMonth.zone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 两个时刻 → 起点与时长；结束不晚于开始时兜底给 30 分钟。
    /// 走 CalMonth 的上海日历，跟 EventEditor 那个轮盘用的是同一把尺子 ——
    /// 轮盘转到几点，存下来就是几点，两边都不许跟着设备时区跑
    static func span(start: Date, end: Date) -> (hour: Int, minute: Int, duration: Int) {
        let cal = CalMonth.calendar
        let s = cal.dateComponents([.hour, .minute], from: start)
        let e = cal.dateComponents([.hour, .minute], from: end)
        let sMin = (s.hour ?? 9) * 60 + (s.minute ?? 0)
        var eMin = (e.hour ?? 10) * 60 + (e.minute ?? 0)
        if eMin <= sMin { eMin = sMin + 30 }
        return (s.hour ?? 9, s.minute ?? 0, eMin - sMin)
    }

    /// 从两个 DatePicker 的时刻拼出事件；结束早于开始时兜底给 30 分钟
    static func makeEvent(title: String, start: Date, end: Date,
                          author: Author, allDay: Bool = false) -> CalEvent {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if allDay {
            return CalEvent(author: author, title: clean,
                            startHour: 0, startMinute: 0, durationMinutes: 0, isAllDay: true)
        }
        let (h, m, dur) = Self.span(start: start, end: end)
        return CalEvent(author: author, title: clean,
                        startHour: h, startMinute: m, durationMinutes: dur)
    }

    /// 时间轴只画 06:00–23:00，选早于 6 点的会看不见，先夹住
    static func clamp(_ date: Date) -> Date {
        let cal = CalMonth.calendar
        let h = cal.component(.hour, from: date)
        if h < 6 { return cal.date(bySettingHour: 6, minute: 0, second: 0, of: date) ?? date }
        return date
    }

    static func time(_ hour: Int, _ minute: Int = 0) -> Date {
        CalMonth.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
