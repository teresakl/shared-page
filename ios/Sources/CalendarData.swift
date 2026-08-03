import Foundation

// ============================================================
// CalendarData.swift — 数据模型 + CalMonth（年月从这里算出来）。
// 现在的分工：年月、天数、前置空格、星期几全交给下面的 CalMonth 推，一处都不写死；
// SampleData 只剩 2026 年 7 月那批样板（跟设计稿一致），翻到别的月它们一个都不会冒出来。
// ============================================================

// ============================================================
// CalMonth — 「哪一年的哪个月」。月视图和日视图现在显示的是哪个月，
// 天数、前置空格、星期、今天是不是在这个月里，全从它推出来，一个都不再写死。
//
// 时区钉死 Asia/Shanghai：后端存的是绝对时间，产品时区就是这个。
// 跟着设备时区跑的话，人在国外一开 app，整本日历会错一天。
// ============================================================
struct CalMonth: Hashable, Comparable, Codable, Sendable {
    let year: Int
    let month: Int          // 1...12

    /// 月份写溢出了自己滚到相邻年份（13 → 明年 1 月，0 → 去年 12 月），
    /// 这样 previous / next 直接加减就行，不用每次先算一遍
    init(year: Int, month: Int) {
        if (1...12).contains(month) {
            self.year = year
            self.month = month
        } else {
            let idx = year * 12 + (month - 1)
            let y = idx >= 0 ? idx / 12 : (idx - 11) / 12   // 负数要往下取整
            self.year = y
            self.month = idx - y * 12 + 1
        }
    }

    /// 从 "2026-08" 这种串解回来，解不动返回 nil（启动参数 -month 用）
    init?(key: String) {
        let p = key.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        self.init(year: y, month: m)
    }

    // —— 时区与日历 ————————————————————————————
    /// 产品时区，跟后端一致，不跟设备走
    static let zone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    /// 公历 + 上面那个时区 + POSIX locale。
    /// locale 钉死是因为月名星期名不能跟着系统语言变（设计稿上写的就是 July）
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    // —— 现在 / 老月份 ————————————————————————
    /// 此时此刻是哪个月（Asia/Shanghai）
    static var current: CalMonth {
        let c = calendar.dateComponents([.year, .month], from: Date())
        return CalMonth(year: c.year ?? 2026, month: c.month ?? 1)
    }

    /// 2026 年 7 月。两个身份：设计稿那批样板数据挂在这个月；
    /// 也是老版本唯一显示过的月份，placed.json 里的裸日号键全归它
    static let sample = CalMonth(year: 2026, month: 7)

    /// 这个月要不要显示 SampleData 里那批样板（25 号纪念日那套）
    var isSampleMonth: Bool { self == CalMonth.sample }

    // —— 基本尺寸 ————————————————————————————
    /// 这个月 1 号那天的零点
    var firstDate: Date {
        CalMonth.calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    /// 这个月有几天
    var daysInMonth: Int {
        CalMonth.calendar.range(of: .day, in: .month, for: firstDate)?.count ?? 30
    }

    /// 1 号是星期几，1=周日 … 7=周六（系统的说法）
    private var firstWeekday: Int {
        CalMonth.calendar.component(.weekday, from: firstDate)
    }

    /// 周一起始的网格里，1 号前面要垫几个上月的格子（0...6）
    var leadingBlanks: Int { (firstWeekday + 5) % 7 }

    /// 月视图网格要画几行。leadingBlanks + 天数，凑够 7 的整倍数。
    /// 4 行（2027-02 那种）到 6 行（2026-08）都会出现
    var weekRows: Int { (leadingBlanks + daysInMonth + 6) / 7 }

    // —— 文案 ————————————————————————————————
    private static let englishMonths = ["January", "February", "March", "April", "May", "June",
                                        "July", "August", "September", "October", "November", "December"]
    private static let englishWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                          "Thursday", "Friday", "Saturday"]

    /// 月视图大标题那个 "July"。写死成表不走 DateFormatter，免得跟着系统语言变
    var monthLabel: String { CalMonth.englishMonths[month - 1] }

    /// 标题旁边那个 "2026"
    var yearLabel: String { String(year) }

    /// 中文月份，配日号用："7月" + "17日"
    var chineseMonth: String { "\(month)月" }

    /// 表头 MON…SUN 和周条 M T W T F S S，周一起始，跟月份无关，永远是这七个
    static let weekdayHeaders = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    static let weekLetters = ["M", "T", "W", "T", "F", "S", "S"]

    /// 这个月的第 day 天是星期几，0=周日 … 6=周六。
    /// day 超出本月范围也算得出来（周条上会用到上月末尾和下月开头那几天）
    func weekdayIndex(of day: Int) -> Int {
        let raw = (firstWeekday - 1 + (day - 1)) % 7
        return raw < 0 ? raw + 7 : raw
    }

    /// 日视图标题右边那个 "Friday"
    func englishWeekday(of day: Int) -> String {
        CalMonth.englishWeekdays[weekdayIndex(of: day)]
    }

    // —— 换算成真实日期 ————————————————————————
    /// 这个月第 day 天的零点（Asia/Shanghai）。接后端时用它换绝对时间
    func date(day: Int) -> Date {
        CalMonth.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? firstDate
    }

    /// 落盘用的日键："2026-08-17"。补零，字典序正好等于时间序
    func dayKey(_ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 月键："2026-08"。事件/便签/跨天安排按月分桶用它
    var key: String { String(format: "%04d-%02d", year, month) }

    /// "2026-08-17" 拆回（月, 日）；不是这个形状就返回 nil。
    /// 迁移和校验用，日常渲染路径上用不到
    static func parseDayKey(_ s: String) -> (month: CalMonth, day: Int)? {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (CalMonth(year: y, month: m), d)
    }

    // —— 今天 ————————————————————————————————
    /// 今天是这个月的几号；今天不在这个月里就是 nil。
    /// 所有「今天」标记（粉数字、· today、已完成红勾）都得先问它一声
    var todayInMonth: Int? {
        let c = CalMonth.calendar.dateComponents([.year, .month, .day], from: Date())
        guard c.year == year, c.month == month else { return nil }
        return c.day
    }

    // —— 翻月 ————————————————————————————————
    var previous: CalMonth { CalMonth(year: year, month: month - 1) }
    var next: CalMonth { CalMonth(year: year, month: month + 1) }

    static func < (a: CalMonth, b: CalMonth) -> Bool {
        a.year == b.year ? a.month < b.month : a.year < b.year
    }
}

enum Author: String {
    // rawValue 只用于界面显示(七处上屏),不参与协议——wire 值见 CalendarDTO.author()
    case kitty = "USER", master = "ASSISTANT", system = "AUTO"
}

struct CalEvent: Identifiable {
    /// 后端那条记录的 id（cal_ 开头）。还没上过后端的时候先拿一个 local_ 的临时值顶着，
    /// POST 回来就地把它换成服务端给的那个 —— 所以是 var 不是 let。
    /// 判断一条东西上没上过后端只看 isLocalOnly，别的判据一律不用
    var id: String = CalID.local()
    var author: Author
    var title: String          // 中文手写标题
    var startHour: Int         // 6–23；全天事件用 isAllDay
    var startMinute: Int
    var durationMinutes: Int
    var isAllDay: Bool = false
    var isAutoSuggestion: Bool = false   // 系统"你们都空闲"建议
    /// 对应后端 calendar_events.event_type。默认 nil = 普通安排。
    /// 特殊日子（下面 stampTypes 那几种）会在月视图那格盖一枚爱心章。
    /// 后端那边这个字段不做任何校验，存进去什么就回来什么，所以只能是裸 String ——
    /// 写成 enum 的话后端哪天多一个类型，整个月的事件会一起解码失败、整月空白
    var eventType: String? = nil

    var timeLabel: String {
        String(format: "%02d:%02d", startHour, startMinute)
    }

    /// 值得盖爱心章的日子：纪念日、生日、约定之夜。
    /// 想加新类型往这里塞一个字符串就行，后端那边 event_type 是自由字符串
    static let stampTypes: Set<String> = ["anniversary", "birthday"]

    var isSpecialDay: Bool { eventType.map(CalEvent.stampTypes.contains) ?? false }
}

/// 跨天安排：一段日子 + 谁的，没有钟点。
/// 月视图上是横贯这几格的半透明色带，标题只写在第一天；日视图进全天行，标 DAY N/M。
/// 不并进 CalEvent 是因为 startHour / durationMinutes 对它全无意义，
/// 硬塞会允许「18:30–20:30 的三天事件」这种没法解释的组合。
///
/// 后端那边存的是一条带 metadata.kind=span 的多天事件，跟普通事件同一张表，
/// 拉回来的时候由 CalMap.materialize 分桶：kind=span 或者跨了不止一天的整日事件走这一路。
/// 这条跨天安排在本月之外还有半截 —— materialize 按当前月裁过它，那半截用户在这一屏上看不见。
/// 记下服务端原来那两个绝对时刻，写回去的时候原样带上，别拿月内日号把看不见的那半截抹掉。
/// 两个字段都是 nil 的时候整个 clip 就是 nil，本地新建的一律没有它
struct CalSpanClip {
    /// 起点在上个月：服务端真正的 starts_at
    var headStart: Date? = nil
    /// 终点在下个月：服务端真正的 ends_at（开区间）
    var tailEnd: Date? = nil

    var isEmpty: Bool { headStart == nil && tailEnd == nil }
}

struct CalSpan: Identifiable {
    /// 跟 CalEvent 的 id 一个规矩：临时的 local_ 先顶着，POST 回来就地换成服务端的
    var id: String = CalID.local()
    var author: Author
    var title: String
    var startDay: Int
    var endDay: Int
    /// 被裁到本月之外的那半截。渲染完全不看它，只有写回后端那一路用得上
    var clip: CalSpanClip? = nil

    /// 反着拖也能用，起止自动摆正
    var days: ClosedRange<Int> { min(startDay, endDay)...max(startDay, endDay) }
    var length: Int { days.count }
    func covers(_ d: Int) -> Bool { days.contains(d) }
    /// 这天是这段里的第几天（1 起）
    func index(of d: Int) -> Int { d - days.lowerBound + 1 }
}

struct CalNote: Identifiable {
    /// 后端那条便签的 id（cmt_ 开头）。还没上过后端的时候先拿 local_ 顶着，
    /// POST 回来就地换成服务端给的 —— 跟 CalEvent、CalSpan 一个规矩，所以是 var
    var id: String = CalID.local()
    var author: Author
    var text: String
    var timestamp: String      // 显示用："07-26 12:30"
    var liked: Bool = false    // 被对方点赞 → 压红心
    /// 贴在哪条日程上。有值 = 这张便签在说那件事；nil = 只关联这一天。
    /// 跟着 CalEvent.id 一起从 UUID 换成了 String —— 事件的临时 id 换成服务端 id 那一下，
    /// 这里也得跟着换，不然纸角上那行「↳ 事件名」会无声消失
    var linkedEventID: String? = nil
    /// 时间轴上的纵坐标。nil = 还没挪过，用设计稿的默认排布 34 + i×116
    var y: CGFloat? = nil
    /// 这张纸贴在哪一页上，"2026-08-05"。后端的 anchor_date。
    /// 绑不绑日程是另一回事 —— 一张纸可以压在某条日程上，但它永远属于某一天
    var anchorDate: String? = nil

    /// 还没上过后端。写操作要靠它判断该 POST 还是 PATCH
    var isLocalOnly: Bool { CalID.isLocal(id) }

    /// 便签纸就那么大，写太多会溢出纸面
    static let maxChars = 40
}

// 一天最多一个分类贴纸（一类一素材）
enum DayCategory { case travel, movie, food }

struct SampleData {
    // 下面这些集合只在 CalMonth.sample（2026 年 7 月）那个月成立，是设计稿那批样板。
    // 读的时候各自先问一句 month.isSampleMonth，翻到别的月一个都不该冒出来
    static let periodDays = 13...18          // 生理期
    // 跨天安排。原来这里是写死的 blockDays = [11,12,20,21,22]，只是画装饰条、
    // 跟事件没有任何关系；07-31 换成真数据，色带由它生成
    static let spans: [CalSpan] = [
        CalSpan(author: .kitty,  title: "短途旅行", startDay: 11, endDay: 12),
        CalSpan(author: .master, title: "出差",     startDay: 20, endDay: 22),
    ]
    // 示例数据清场：下面这几路示例贴纸全部倒空，渲染代码原样留着 ——
    // 以后接真数据时往这些集合里填就直接显示，不用再写一遍。
    //
    // 原来这里还有 newDays / anniversaryDays / strikeDays 三个写死的集合，07-31 下午全部退役：
    //   · 爱心章  → 改由事件自己说了算，看 CalEvent.isSpecialDay（纪念日/生日/约定之夜）
    //   · 感叹号  → 改由 CalendarStore.unseenDays 说了算（AI 侧改过、用户还没看的日子）
    //   · 红笔划掉线 → 按定稿去掉，后端也没有对应的东西，整条拿掉
    static let photoDays: Set<Int> = []                     // 月视图空相框
    static let dayPhotoDays: Set<Int> = []                  // 日视图时间轴上的空相框
    static let catStickerDays: Set<Int> = []                // 日视图猫贴纸
    // 分类贴纸：月视图只贴 travel/food（movie 只出现在日视图，设计如此）
    static let category: [Int: DayCategory] = [:]
    static let monthCellCategories: Set<Int> = []           // 月视图实际渲染贴纸的日子

    static let events: [Int: [CalEvent]] = [
        1:  [CalEvent(author: .kitty,  title: "拿快递",   startHour: 14, startMinute: 0,  durationMinutes: 30)],
        3:  [CalEvent(author: .master, title: "看电影",   startHour: 20, startMinute: 0,  durationMinutes: 150)],
        4:  [CalEvent(author: .kitty,  title: "逛菜市场", startHour: 9,  startMinute: 30, durationMinutes: 90)],
        6:  [CalEvent(author: .master, title: "牙医",     startHour: 10, startMinute: 30, durationMinutes: 60)],
        8:  [CalEvent(author: .kitty,  title: "做蛋糕",   startHour: 0,  startMinute: 0,  durationMinutes: 0, isAllDay: true)],
        12: [CalEvent(author: .master, title: "回程",     startHour: 18, startMinute: 40, durationMinutes: 130)],
        14: [CalEvent(author: .kitty,  title: "交作业",   startHour: 23, startMinute: 0,  durationMinutes: 59)],
        17: [CalEvent(author: .kitty,  title: "剪头发",   startHour: 15, startMinute: 0,  durationMinutes: 60),
             CalEvent(author: .master, title: "陪你练答辩", startHour: 18, startMinute: 30, durationMinutes: 120),
             CalEvent(author: .system, title: "17:30 之后你没别的安排", startHour: 17, startMinute: 30, durationMinutes: 60, isAutoSuggestion: true)],
        18: [CalEvent(author: .system, title: "预计生理期结束", startHour: 0, startMinute: 0, durationMinutes: 0, isAllDay: true)],
        23: [CalEvent(author: .kitty,  title: "图书馆",   startHour: 13, startMinute: 0,  durationMinutes: 240)],
        25: [CalEvent(author: .master, title: "纪念日",   startHour: 0,  startMinute: 0,  durationMinutes: 0, isAllDay: true, eventType: "anniversary")],
        28: [CalEvent(author: .master, title: "体检",     startHour: 8,  startMinute: 0,  durationMinutes: 90),
             CalEvent(author: .kitty,  title: "去机场接人", startHour: 11, startMinute: 0,  durationMinutes: 60)],
        31: [CalEvent(author: .kitty,  title: "月底看电影", startHour: 20, startMinute: 30, durationMinutes: 120)],
    ]

    static let notes: [Int: [CalNote]] = [
        3:  [CalNote(author: .master, text: "查了下，评价不错", timestamp: "昨天 21:04"),
             CalNote(author: .kitty,  text: "那就看这部",     timestamp: "昨天 21:11")],
        8:  [CalNote(author: .kitty,  text: "想吃芋泥的那个",   timestamp: "07-24")],
        17: [CalNote(author: .kitty,  text: "答辩稿卡住了",     timestamp: "07-26 12:30"),
             CalNote(author: .master, text: "发我，我帮你捋",   timestamp: "07-26 12:41"),
             CalNote(author: .kitty,  text: "捋完了，好多了",   timestamp: "07-26 12:44", liked: true)],
        25: [CalNote(author: .kitty,  text: "别让我忘了",      timestamp: "07-20")],
    ]
}

// ============================================================
// 下面这几样 store / 月视图两边都要读，只能有这一份，别处不许再抄
// ============================================================

/// 还没上过后端的东西，id 长这样。后端的 id 一律是 cal_ 开头（legacy 那批是 cal_legacy_），撞不上
enum CalID {
    static let localPrefix = "local_"
    static func local() -> String { localPrefix + UUID().uuidString }
    static func isLocal(_ id: String) -> Bool { id.hasPrefix(localPrefix) }
}

enum AppMode {
    /// -sample：走纯本地样板，一个请求都不发。对着设计稿看那一屏的时候用。
    /// 跟 -month / -day / -openDay / -fabOpen / -tray 是同一个地方加（scheme 的启动参数）
    static let isSample = ProcessInfo.processInfo.arguments.contains("-sample")
}

extension CalEvent { var isLocalOnly: Bool { CalID.isLocal(id) } }
extension CalSpan  { var isLocalOnly: Bool { CalID.isLocal(id) } }
