import Foundation

// ============================================================
// CalendarDTO.swift — 后端 JSON 的原样，加上「后端一条记录 ⇄ 前端 CalEvent/CalSpan/生理期」的换算。
//
// 三件事在这个文件里定死，别处不许再抄一份：
//   1. EventDTO：后端列表接口那 17 个字段里，前端认下来的 16 个。
//      漏的那个是 source_message_id（后端记「这条是从哪条消息解析出来的」，前端一处都用不到）；
//      Decodable 对没声明的键直接跳过，不影响解码
//   2. CalMap.materialize：一次拉取的结果 → 当月的事件桶 / 跨天安排 / 生理期段
//   3. CalMap.createBody / patchBody：前端的东西 → 写回去的 body
//
// 时间的规矩（07-31 实测的，别自己改）：
//   · 后端回来的时间一律是 UTC，形如 2026-08-05T06:30:00+00:00
//   · 写回去一律用带 +08:00 的串（CalTime.isoShanghai）
//   · 查月份的 from/to 用 Z 结尾的 UTC 串（CalTime.isoUTC），躲开 + 号那个坑
//   · ends_at 是开区间。8/20 到 8/22 三天，存的 ends_at 是 8/23T00:00+08:00。
//     换算回日号必须先减一秒再取那天，少减一次就少涂一格
// ============================================================

// MARK: - 任意 JSON（metadata 用）

/// metadata 后端不做任何 schema 校验，嵌套对象、数组、bool 都原样往返，
/// 所以这里得有个能装下任意 JSON 的东西，不能写成固定 struct
indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "认不出来的 JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
}

// MARK: - 读：后端一条事件

/// 列表接口 GET /events 每个元素的形状。
/// CodingKeys 全部手写，不用 convertFromSnakeCase —— 那个策略会连 metadata 里的键
/// 一起改名（legacy_recurring 会变成 legacyRecurring），metadata 就 round-trip 不回去了
struct EventDTO: Decodable, Sendable {
    let id: String
    let title: String
    let description: String?
    let startsAt: Date
    let endsAt: Date?
    let timezone: String?
    let precision: String?
    /// 后端对这个字段零校验，存进去什么就回什么，所以只能是裸 String，
    /// 写成 enum 的话后端哪天多一个类型，整个月的事件会一起解码失败、整月空白
    let eventType: String?
    let source: String?
    let createdBy: String?
    let revision: Int?
    let status: String?
    let metadata: JSONValue?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, description, timezone, precision, source, revision, status, metadata
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case eventType = "event_type"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// 软删的记录列表接口会滤掉，但单查 GET /events/{id} 照样 200 返回，
    /// 不自己判一下的话删掉的事件会诈尸
    var isActive: Bool { (status ?? "active") == "active" }
}

/// GET /events 的外壳
struct EventListDTO: Decodable, Sendable {
    let events: [EventDTO]
    let count: Int?
}

// MARK: - 写：发回去的 body

/// POST / PATCH 的 body。全是 Optional，编译器合成的 encode 对 Optional 走 encodeIfPresent，
/// 没填的字段根本不会出现在 JSON 里 —— PATCH 就是这么做部分更新的。
///
/// metadata 特别注意：PATCH 里带上 metadata 是整体替换不是合并，
/// 所以改标题改日期的时候一个字都不要带它，免得把别处写进去的键抹掉
struct EventWriteDTO: Encodable, Sendable {
    var title: String?
    var startsAt: String?
    var endsAt: String?
    var precision: String?
    var eventType: String?
    var metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case title, precision, metadata
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case eventType = "event_type"
    }
}

// MARK: - 时间串

enum CalTime {
    /// 写回后端用：2026-08-05T14:30:00+08:00。
    /// 时区钉死上海，跟 CalMonth 那套是同一把尺子
    static func isoShanghai(_ d: Date) -> String { shanghaiFormatter.string(from: d) }

    /// 查月份的 from/to 用：2026-07-31T16:00:00Z。
    /// 用 Z 是为了躲开 + 号 —— URLComponents 不会把查询串里的 + 转义成 %2B，
    /// 后端拿到会把它当成空格，直接 400 Invalid isoformat string。实测过，别赌
    static func isoUTC(_ d: Date) -> String { utcFormatter.string(from: d) }

    private static let shanghaiFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = CalMonth.zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f
    }()

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()
}

// MARK: - 换算

enum CalMap {

    /// 一次拉取换算出来的当月内容。三样东西各归各的桶
    struct MonthPayload: Sendable {
        var events: [Int: [CalEvent]] = [:]
        var spans: [CalSpan] = []
        /// 生理期：每段一个闭区间日号。跨月的已经裁到本月内，一个月可能有两段
        var periods: [ClosedRange<Int>] = []
    }

    // —— 读回来 ————————————————————————————

    /// 后端一批记录 → 当月要画的东西。跨月的按当前月裁剪，完全不在本月的直接丢掉
    static func materialize(_ dtos: [EventDTO], month: CalMonth) -> MonthPayload {
        var out = MonthPayload()
        let cal = CalMonth.calendar

        for dto in dtos {
            guard dto.isActive else { continue }

            let starts = dto.startsAt
            let isDay = (dto.precision ?? "hour") == "day"
            // ends_at 实测从来不为 null（缺省后端自己补），兜底照后端那套规矩补
            let ends = dto.endsAt ?? starts.addingTimeInterval(isDay ? 86_400 : 3_600)

            let startIdx = dayIndex(of: starts, in: month)
            // 整天的记录只认日子不认钟点。后端对 precision=day 一点都不把时间拍到零点：
            // AI 侧的工具或者自动抽取写一条「8/27 全天」，很可能存成 8/27 09:00 → 8/28 09:00。
            // 开区间的终点先落回它自己那天的零点，不然这条会被下面算成横跨 8/27–8/28 的两天色带
            let effEnd = isDay ? cal.startOfDay(for: ends) : ends
            // ends_at 是开区间：减一秒才落回最后那个真正被覆盖的日子
            let endIdx = max(startIdx, dayIndex(of: effEnd.addingTimeInterval(-1), in: month))

            let isPeriod = (dto.eventType ?? "") == "period"
            let markedSpan = dto.metadata?.objectValue?["kind"]?.stringValue == "span"
            // 跨了不止一天的整天事件也当跨天安排 —— 后端那边（或者 AI 侧）
            // 写进来的多天记录不一定带 kind 标记，光认 metadata 会把它压成一天。
            // 注意必须带上 isDay：23:00–01:00 那种跨午夜的钟点事件不算跨天安排
            let spanShaped = isPeriod || markedSpan || (isDay && endIdx > startIdx)

            if spanShaped {
                guard let r = clip(startIdx...endIdx, to: month) else { continue }
                if isPeriod {
                    out.periods.append(r)
                } else {
                    // 裁掉的那半截记下来。用户在这一屏上只看得见月内这几天，
                    // 但改个标题就会走 patchBody 重算 starts_at/ends_at ——
                    // 不把服务端原来那两个时刻带着，月外那几天会被这一刀无声抹掉
                    var cut = CalSpanClip()
                    if startIdx < 1 { cut.headStart = starts }
                    if endIdx > month.daysInMonth { cut.tailEnd = ends }
                    out.spans.append(CalSpan(id: dto.id,
                                             author: author(dto.createdBy),
                                             title: dto.title,
                                             startDay: r.lowerBound,
                                             endDay: r.upperBound,
                                             clip: cut.isEmpty ? nil : cut))
                }
                continue
            }

            // 单天：起始日不在本月就丢掉（各月画各月的，不做跨月逻辑）
            guard (1...month.daysInMonth).contains(startIdx) else { continue }

            let ev: CalEvent
            if isDay {
                ev = CalEvent(id: dto.id, author: author(dto.createdBy), title: dto.title,
                              startHour: 0, startMinute: 0, durationMinutes: 0,
                              isAllDay: true, eventType: dto.eventType)
            } else {
                let c = cal.dateComponents([.hour, .minute], from: starts)
                let dur = max(1, Int(ends.timeIntervalSince(starts) / 60))
                ev = CalEvent(id: dto.id, author: author(dto.createdBy), title: dto.title,
                              startHour: c.hour ?? 0, startMinute: c.minute ?? 0,
                              durationMinutes: dur,
                              isAllDay: false, eventType: dto.eventType)
            }
            out.events[startIdx, default: []].append(ev)
        }

        // 时间轴不能串，按开始时间排一遍
        for (d, list) in out.events {
            out.events[d] = list.sorted {
                ($0.startHour * 60 + $0.startMinute) < ($1.startHour * 60 + $1.startMinute)
            }
        }
        // 起始日在前；同一天开始的长的排前面，色带堆叠顺序才不会跳（跟 store.sortSpans 一个规矩）
        out.spans.sort {
            $0.days.lowerBound == $1.days.lowerBound
                ? $0.length > $1.length
                : $0.days.lowerBound < $1.days.lowerBound
        }
        out.periods.sort { $0.lowerBound < $1.lowerBound }
        return out
    }

    /// created_by → 笔迹。后端现在只写得出 kitty，legacy 那批是 system；
    /// AI 侧的 wire 值是 master
    static func author(_ createdBy: String?) -> Author {
        switch (createdBy ?? "").lowercased() {
        case "kitty": return .kitty
        case "master", "assistant": return .master
        default: return .system
        }
    }

    /// 这个时刻落在本月的第几天。可能 ≤ 0（上个月）或 > daysInMonth（下个月），调用方自己裁
    static func dayIndex(of date: Date, in month: CalMonth) -> Int {
        let cal = CalMonth.calendar
        let a = cal.startOfDay(for: month.firstDate)
        let b = cal.startOfDay(for: date)
        return (cal.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }

    /// 把一段日号裁进本月。完全不在本月返回 nil
    static func clip(_ r: ClosedRange<Int>, to month: CalMonth) -> ClosedRange<Int>? {
        let lo = max(1, r.lowerBound)
        let hi = min(month.daysInMonth, r.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    // —— 写回去 ————————————————————————————

    /// 新建一条事件。全天的走 precision=day、ends_at 是第二天零点（开区间）
    static func createBody(_ e: CalEvent, on day: Int, month: CalMonth) -> EventWriteDTO {
        var b = timeFields(e, on: day, month: month)
        b.title = e.title
        b.eventType = e.eventType
        return b
    }

    /// 改一条事件。metadata 一个字都不带 —— 带了就是整体替换，会把别处写进去的键抹掉
    static func patchBody(_ e: CalEvent, on day: Int, month: CalMonth) -> EventWriteDTO {
        var b = timeFields(e, on: day, month: month)
        b.title = e.title
        return b
    }

    private static func timeFields(_ e: CalEvent, on day: Int, month: CalMonth) -> EventWriteDTO {
        var b = EventWriteDTO()
        let midnight = month.date(day: day)
        if e.isAllDay {
            b.precision = "day"
            b.startsAt = CalTime.isoShanghai(midnight)
            b.endsAt = CalTime.isoShanghai(nextMidnight(after: midnight))
        } else {
            let s = midnight.addingTimeInterval(TimeInterval(e.startHour * 3600 + e.startMinute * 60))
            b.precision = "hour"
            b.startsAt = CalTime.isoShanghai(s)
            b.endsAt = CalTime.isoShanghai(s.addingTimeInterval(TimeInterval(max(1, e.durationMinutes) * 60)))
        }
        return b
    }

    /// 新建一条跨天安排。metadata 打上 kind=span，拉回来才认得出它该进色带那一路
    static func createBody(_ s: CalSpan, month: CalMonth) -> EventWriteDTO {
        var b = spanTimeFields(s, month: month)
        b.title = s.title
        b.metadata = .object(["kind": .string("span")])
        return b
    }

    /// 改一条跨天安排。同样不带 metadata
    static func patchBody(_ s: CalSpan, month: CalMonth) -> EventWriteDTO {
        var b = spanTimeFields(s, month: month)
        b.title = s.title
        return b
    }

    private static func spanTimeFields(_ s: CalSpan, month: CalMonth) -> EventWriteDTO {
        var b = EventWriteDTO()
        let r = s.days
        b.precision = "day"
        var startDate = month.date(day: r.lowerBound)
        // 末日的第二天零点。写成末日当天零点就会少涂一格，这是最容易出的差一天
        var endDate = nextMidnight(after: month.date(day: r.upperBound))
        // 这条在本月之外还有半截：只要用户没动那一端（还贴着月首/月末），
        // 就把服务端原来那个时刻原样发回去。不然用户在九月给一条 8/30–9/2 的安排改个名字，
        // 8/30、8/31 会跟着这一发 PATCH 一起没掉，而且当场一点提示都没有
        if let cut = s.clip {
            if let h = cut.headStart, r.lowerBound == 1 { startDate = h }
            if let t = cut.tailEnd, r.upperBound == month.daysInMonth { endDate = t }
        }
        b.startsAt = CalTime.isoShanghai(startDate)
        b.endsAt = CalTime.isoShanghai(endDate)
        return b
    }

    /// 「去掉这天」正好挖在被裁过的那一端：本月之外那半截得单独存成一条，
    /// 不然它会跟着这一刀一起没掉（用户根本看不见它，也就永远不知道丢了什么）。
    /// 返回 nil = 这一端没被裁过，按老路走一发 PATCH 就行。
    ///
    /// 举例：服务端一条 7/30–8/2，用户在八月的 8/1 上点了「去掉这天」——
    /// 这里出的 body 是 7/30 → 8/1（开区间），本月剩下的 8/2 由原来那条 PATCH 收着
    static func hiddenHalfBody(_ s: CalSpan, removing day: Int, month: CalMonth) -> EventWriteDTO? {
        guard let cut = s.clip else { return nil }
        let r = s.days
        var b = EventWriteDTO()
        b.title = s.title
        b.precision = "day"
        b.metadata = .object(["kind": .string("span")])
        if day == r.lowerBound, r.lowerBound == 1, let h = cut.headStart {
            b.startsAt = CalTime.isoShanghai(h)
            b.endsAt = CalTime.isoShanghai(month.date(day: day))   // 开区间，正好停在被挖掉那天的零点
            return b
        }
        if day == r.upperBound, r.upperBound == month.daysInMonth, let t = cut.tailEnd {
            b.startsAt = CalTime.isoShanghai(nextMidnight(after: month.date(day: day)))
            b.endsAt = CalTime.isoShanghai(t)
            return b
        }
        return nil
    }

    /// 第二天零点。跨月末也算得对（8/31 → 9/1），不能简单地 day + 1
    static func nextMidnight(after d: Date) -> Date {
        CalMonth.calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
    }
}


// ============================================================
// 便签的 DTO
//
// 后端那张表跟事件是分开的（calendar_comments），有自己的一组端点。
// event_id 可空 = 贴在一整天上、不关于任何日程，那是用户前端撕下一张纸时的默认状态。
// anchor_date 永远有值 = 这张纸贴在哪一页上。
// ============================================================

struct NoteDTO: Decodable, Sendable {
    let id: String
    let eventId: String?
    let anchorDate: String
    let author: String?
    let body: String
    let y: Double?
    let liked: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, author, body, y, liked
        case eventId = "event_id"
        case anchorDate = "anchor_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    var isActive: Bool { deletedAt == nil }
}

struct NoteListDTO: Decodable, Sendable {
    let notes: [NoteDTO]
}

/// 写便签的 body。只把这次真要动的那几项发出去，别的一律不出现在 JSON 里 ——
/// 后端是「给了就覆盖」，多发一个字段就等于把它改成那个值
struct NoteWriteDTO: Encodable, Sendable {
    var body: String? = nil
    var anchorDate: String? = nil
    var y: Double? = nil
    var liked: Bool? = nil
    /// 三态，所以是双层可选：
    ///   nil        这次不动 event_id
    ///   .some(nil) 明确解绑，发一个 JSON null 上去
    ///   .some(id)  绑到那条日程上
    /// 少了这一层的话，「把便签从日程上拖下来」这个动作永远发不出去
    var eventID: String?? = nil

    enum CodingKeys: String, CodingKey {
        case body, y, liked
        case anchorDate = "anchor_date"
        case eventID = "event_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(anchorDate, forKey: .anchorDate)
        try c.encodeIfPresent(y, forKey: .y)
        try c.encodeIfPresent(liked, forKey: .liked)
        if let outer = eventID {
            if let id = outer { try c.encode(id, forKey: .eventID) }
            else { try c.encodeNil(forKey: .eventID) }
        }
    }
}

extension CalMap {

    /// 后端一条便签 → 前端的 CalNote。落在哪一天由 anchor_date 说了算
    static func note(_ dto: NoteDTO) -> (day: Int, note: CalNote)? {
        guard let (m, day) = CalMonth.parseDayKey(dto.anchorDate) else { return nil }
        _ = m
        return (day, CalNote(
            id: dto.id,
            author: author(dto.author),
            text: NoteFit.truncate(dto.body, author: author(dto.author)),
            timestamp: stamp(dto.createdAt),
            liked: dto.liked ?? false,
            linkedEventID: dto.eventId,
            y: dto.y.map { CGFloat($0) },
            anchorDate: dto.anchorDate
        ))
    }

    /// 整月的便签按天分桶。不属于这个月的直接丢掉（正常不会有，接口是按月拉的）
    static func notesByDay(_ dtos: [NoteDTO], month: CalMonth) -> [Int: [CalNote]] {
        var out: [Int: [CalNote]] = [:]
        let prefix = month.key + "-"
        for dto in dtos where dto.isActive && dto.anchorDate.hasPrefix(prefix) {
            guard let hit = note(dto) else { continue }
            out[hit.day, default: []].append(hit.note)
        }
        for (day, list) in out {
            out[day] = list.sorted { ($0.y ?? 0) < ($1.y ?? 0) }
        }
        return out
    }

    /// 新建一张便签发出去的 body
    static func createBody(_ n: CalNote, on day: Int, month: CalMonth) -> NoteWriteDTO {
        NoteWriteDTO(
            body: n.text,
            anchorDate: month.dayKey(day),
            y: n.y.map { Double($0) },
            eventID: n.linkedEventID.map { Optional($0) } ?? .some(nil)
        )
    }

    /// 便签上那行时间戳。后端只给绝对时刻，显示成什么样是前端的事，
    /// 走 CalendarStore.stamp 那一套（已经钉死上海时区）
    private static func stamp(_ d: Date?) -> String {
        CalendarStore.stamp(d ?? Date())
    }
}
