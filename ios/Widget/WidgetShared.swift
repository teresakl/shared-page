import SwiftUI

// ============================================================
// WidgetShared.swift — 桌面小组件的数据获取 + 视图。
//
// 这个文件同时编进主 app 和小组件两个 target:
//   · 小组件用它当真身
//   · 主 app 用它跑 -widgetProbe(把卡片渲染成 PNG 给静态验收,
//     小组件本体没法自动化截图)
// 所以这里【不许】import WidgetKit、不许出现 @main —— 那些在
// CalendarWidget.swift 里,只归小组件 target。
//
// 小组件是独立小程序,拿不到主 app 的 Theme/CalMonth,数据也不共享:
// 它自己带一套最小的取数(URLSession 直连网关,纯在线,不落盘 ——
// 同一套规矩在小组件上照样成立)和一套抄自 Theme.swift 定稿的色值字体。
// 改配色请去 Theme.swift 改完再同步这里,别让两边分家。
// ============================================================

// —— 定稿常量(抄自 Theme.swift,2026-08-02 版)——————————
enum WTheme {
    static let kitty      = Color(red: 0xD4/255, green: 0x73/255, blue: 0x7F/255)
    static let master     = Color(red: 0x62/255, green: 0x9B/255, blue: 0xA7/255)
    static let noteKitty  = Color(red: 0xC9/255, green: 0x55/255, blue: 0x6A/255)
    static let noteMaster = Color(red: 0x27/255, green: 0x4E/255, blue: 0x56/255)
    static let title      = Color(red: 0x5C/255, green: 0x42/255, blue: 0x49/255)
    static let sub        = Color(red: 0x86/255, green: 0x64/255, blue: 0x6A/255).opacity(0.62)
    static let dim        = Color(red: 0x86/255, green: 0x64/255, blue: 0x6A/255).opacity(0.42)
    static let hourLbl    = Color(red: 0x86/255, green: 0x64/255, blue: 0x6A/255).opacity(0.50)
    static let border     = Color(red: 0xE4/255, green: 0xC2/255, blue: 0xC6/255)
    static let texture    = Color(red: 0xD6/255, green: 0xAA/255, blue: 0xB0/255).opacity(0.20)

    static func handFont(_ size: CGFloat, master: Bool) -> Font {
        // 开源版:两种笔迹统一霞鹜文楷,想换手写体把这里的字体名换成自己的
        master ? .custom("LXGWWenKai-Regular", size: size)
               : .custom("LXGWWenKai-Regular", size: size)
    }
    static func bodyFont(_ size: CGFloat) -> Font { .custom("LXGWWenKai-Regular", size: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("SpaceMono-Regular", size: size) }
    static func serif(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Regular", size: size) }
    static func script(_ size: CGFloat) -> Font { .custom("Caveat-Medium", size: size) }
}

// —— 卡片上的一行日程 ————————————————————————
struct WItem: Identifiable {
    let id: String
    let isMaster: Bool
    let isSystem: Bool
    /// "14:00" / "整天"
    let timeLabel: String
    let text: String
}

/// 右下角那张便签纸:当天最新的一张,谁写的都行(用户 8/2 定的形态)
struct WLatestNote {
    let isMaster: Bool
    let body: String
    /// "08-02 19:53",跟 app 里便签的时间戳同款
    let stamp: String
}

struct WDaySnapshot {
    var date: Date = Date()
    var items: [WItem] = []
    var latestNote: WLatestNote? = nil
    var failed = false

    static let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
}

// —— 取数:小组件自己直连网关,拉今天的日程和便签 ——————————
enum WidgetFetch {
    static func today() async -> WDaySnapshot {
        var snap = WDaySnapshot()
        let cal = WDaySnapshot.calendar
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart),
              let base = URL(string: CalendarSecrets.baseURL) else {
            snap.failed = true
            return snap
        }
        let iso = ISO8601DateFormatter()

        let dayKeyFmt = DateFormatter()
        dayKeyFmt.timeZone = WDaySnapshot.zone
        dayKeyFmt.dateFormat = "yyyy-MM-dd"
        let dayKey = dayKeyFmt.string(from: now)

        var evComps = URLComponents(url: base.appendingPathComponent("events"),
                                    resolvingAgainstBaseURL: false)
        evComps?.queryItems = [
            URLQueryItem(name: "from", value: iso.string(from: dayStart)),
            URLQueryItem(name: "to", value: iso.string(from: dayEnd)),
        ]
        var ntComps = URLComponents(url: base.appendingPathComponent("notes"),
                                    resolvingAgainstBaseURL: false)
        ntComps?.queryItems = [URLQueryItem(name: "date", value: dayKey)]

        async let evData = get(evComps?.url)
        async let ntData = get(ntComps?.url)
        let (ev, nt) = await (evData, ntData)
        guard let ev, let nt else {
            snap.failed = true
            return snap
        }

        var items: [WItem] = []
        let timeFmt = DateFormatter()
        timeFmt.timeZone = WDaySnapshot.zone
        timeFmt.dateFormat = "HH:mm"

        if let list = try? JSONDecoder().decode(WEventList.self, from: ev) {
            let parse = ISO8601DateFormatter()
            for e in list.events.sorted(by: { $0.starts_at < $1.starts_at }) {
                let start = parse.date(from: e.starts_at)
                let allDay = e.precision == "day"
                let label = allDay ? "整天" : (start.map { timeFmt.string(from: $0) } ?? "")
                let author = e.created_by ?? ""
                items.append(WItem(
                    id: e.id,
                    isMaster: author == "master",
                    isSystem: !(author == "master" || author == "kitty"),
                    timeLabel: label,
                    text: e.event_type == "period" ? "生理期" : (e.title ?? "")))
            }
        } else { snap.failed = true }

        if let list = try? JSONDecoder().decode(WNoteList.self, from: nt) {
            // 只挑最新的一张上卡片(定稿:一天一张,谁写的都行)
            if let n = list.notes.max(by: { ($0.created_at ?? "") < ($1.created_at ?? "") }),
               let body = n.body, !body.isEmpty {
                let stampFmt = DateFormatter()
                stampFmt.timeZone = WDaySnapshot.zone
                stampFmt.dateFormat = "MM-dd HH:mm"
                let parse = ISO8601DateFormatter()
                let stamp = n.created_at.flatMap { parse.date(from: $0) }
                    .map { stampFmt.string(from: $0) } ?? ""
                snap.latestNote = WLatestNote(
                    isMaster: n.author == "master", body: body, stamp: stamp)
            }
        } else { snap.failed = true }

        snap.items = items
        return snap
    }

    private static func get(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(CalendarSecrets.token, forHTTPHeaderField: "X-Calendar-Token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private struct WEventList: Decodable { let events: [WEventDTO] }
    private struct WEventDTO: Decodable {
        let id: String
        let title: String?
        let starts_at: String
        let precision: String?
        let event_type: String?
        let created_by: String?
    }
    private struct WNoteList: Decodable { let notes: [WNoteDTO] }
    private struct WNoteDTO: Decodable {
        let id: String
        let author: String?
        let body: String?
        let created_at: String?
    }
}

// —— 中号卡片 ————————————————————————————————
// 左边今天的日期,右边今天的日程和便签,方格纸打底。
// 字号配色全部对着 app 的定稿气质来,改样式先对齐 app 定稿
struct WidgetMediumView: View {
    var snap: WDaySnapshot

    private var cal: Calendar { WDaySnapshot.calendar }

    var body: some View {
        HStack(spacing: 12) {
            dateBlock.frame(width: 88)
            Rectangle().fill(WTheme.border).frame(width: 1.2)
                .padding(.vertical, 6)
            rows
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { gridPaper }
    }

    private var dateBlock: some View {
        VStack(spacing: 0) {
            Text("\(cal.component(.month, from: snap.date))月")
                .font(WTheme.bodyFont(12)).foregroundColor(WTheme.sub)
            Text("\(cal.component(.day, from: snap.date))")
                .font(WTheme.serif(46)).foregroundColor(WTheme.title)
                .padding(.vertical, -4)
            Text(weekdayWord)
                .font(WTheme.script(15)).foregroundColor(WTheme.sub)
        }
    }

    private var weekdayWord: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = WDaySnapshot.zone
        f.dateFormat = "EEEE"
        return f.string(from: snap.date)
    }

    @ViewBuilder private var rows: some View {
        if snap.failed && snap.items.isEmpty && snap.latestNote == nil {
            VStack(spacing: 2) {
                Text("没连上").font(WTheme.bodyFont(12)).foregroundColor(WTheme.dim)
                Text("待会儿它自己会再试").font(WTheme.bodyFont(9)).foregroundColor(WTheme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snap.items.isEmpty && snap.latestNote == nil {
            VStack(spacing: 2) {
                Text("这一天还空着").font(WTheme.bodyFont(13)).foregroundColor(WTheme.dim)
                Text("nothing here yet").font(WTheme.script(12)).foregroundColor(WTheme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 日程列表在上,最新那张便签纸落右下角(定稿版式)
            ZStack(alignment: .bottomTrailing) {
                let maxRows = snap.latestNote == nil ? 4 : 2
                VStack(alignment: .leading, spacing: 5) {
                    if snap.items.isEmpty {
                        Text("今天没有安排")
                            .font(WTheme.bodyFont(11)).foregroundColor(WTheme.dim)
                    }
                    ForEach(snap.items.prefix(maxRows)) { item in row(item) }
                    if snap.items.count > maxRows {
                        Text("还有 \(snap.items.count - maxRows) 条")
                            .font(WTheme.mono(8)).foregroundColor(WTheme.dim)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let note = snap.latestNote {
                    notePaper(note)
                        .padding(.trailing, 2)
                        .padding(.bottom, 2)
                }
            }
        }
    }

    private func row(_ item: WItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.timeLabel)
                .font(WTheme.mono(9)).foregroundColor(WTheme.hourLbl)
                .frame(width: 34, alignment: .leading)
            Text(item.text)
                .font(item.isSystem ? WTheme.bodyFont(11)
                      : WTheme.handFont(13, master: item.isMaster))
                .kerning(item.isSystem || item.isMaster ? 0 : -1)
                .foregroundColor(item.isSystem ? WTheme.dim
                                 : (item.isMaster ? WTheme.noteMaster : WTheme.noteKitty))
                .lineLimit(1)
        }
    }

    /// 右下角那张小便签纸:app 里同款纸素材 + 格纹胶带(AI 侧的转青,跟 GinghamTape 同参数)
    private func notePaper(_ note: WLatestNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(note.isMaster ? "ASSISTANT" : "USER") · \(note.stamp)")
                .font(WTheme.mono(6)).kerning(0.3)
                .foregroundColor(note.isMaster ? WTheme.master : WTheme.kitty)
            Text(note.body)
                .font(WTheme.handFont(11, master: note.isMaster))
                .kerning(note.isMaster ? 0 : -1)
                .foregroundColor(note.isMaster ? WTheme.noteMaster : WTheme.noteKitty)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9))
        .frame(width: 138, alignment: .topLeading)
        .background(Image("grid-scrap-strip").resizable())
        .overlay(alignment: note.isMaster ? .topLeading : .top) {
            Image("gingham-tape-short").resizable()
                .frame(width: 30, height: 14)
                .hueRotation(.degrees(note.isMaster ? 183 : 0))
                .saturation(note.isMaster ? 0.78 : 1)
                .brightness(note.isMaster ? 0.04 : 0)
                .rotationEffect(.degrees(note.isMaster ? -19 : 6))
                .offset(x: note.isMaster ? -7 : 0, y: -6)
        }
        .rotationEffect(.degrees(-2))
        .shadow(color: Color(red: 0x96/255, green: 0x78/255, blue: 0x7D/255).opacity(0.3),
                radius: 2.5, x: 1.5, y: 2)
    }

    /// 13pt 方格纸,跟 app 里 GridPaperTexture 同一个纹理密度和线色
    private var gridPaper: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += 13
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += 13
            }
            ctx.stroke(path, with: .color(WTheme.texture), lineWidth: 0.7)
        }
    }
}
