import SwiftUI

// ============================================================
// MonthView.swift — 1a 月视图（402pt 设计宽度，数值 1:1 来自设计稿）
// 层级顺序（每个格子，自下而上）：
//   方格纹理 → 非本月斜线 → 连续日程色块 → 生理期条 → 今天印章 →
//   纪念日印章 → 选中粉圈 → 日期数字 → 事件文字(+划掉) →
//   空相框 → 分类贴纸 → NEW!!
// ============================================================

struct MonthView: View {
    @Environment(CalendarStore.self) private var store
    /// 缩略图要按 stickerID 反查素材，这里只读不写
    @State private var monthLibrary = StickerLibrary()
    @Binding var selectedDay: Int
    var openDay: (Int) -> Void

    private let cellH: CGFloat = 88

    // —— 拖选跨天安排 ——
    // 点和长按拖走同一个 DragGesture，自己量时长和位移，不让两个手势互相仲裁
    @State private var gridW: CGFloat = 0
    @State private var pressAt: CGPoint? = nil     // 这一次触摸的落点，nil = 手指没在屏幕上
    @State private var pressDay: Int? = nil
    @State private var lastAt: CGPoint? = nil
    @State private var pickFrom: Int? = nil        // 有值 = 已经进入拉带模式
    @State private var pickTo: Int? = nil
    @State private var pickTick = 0                // 震动
    @State private var handled = false             // 这一按已经被色带接走，后面既不拖选也不算点
    // 调试：-spanNew 直接弹新建，-spanEdit 直接弹「出差」那条的改
    @State private var sheet: SpanSheet? = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-spanNew")  { return .new(SpanDraft(start: 20, end: 22)) }
        // 这条样板只在 -sample 模式下才在桶里，两个参数得一起用；
        // 另外它挂在 2026-07 的桶里，启动时若不在七月，编辑保存会找不到而无声无效
        if args.contains("-spanEdit"), AppMode.isSample { return .edit(SampleData.spans[1]) }
        return nil
    }()

    private var pickRange: ClosedRange<Int>? {
        guard let a = pickFrom, let b = pickTo else { return nil }
        return min(a, b)...max(a, b)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            card.padding(.horizontal, 12).padding(.top, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .medium), trigger: pickTick)
        .sheet(item: $sheet) { item in
            switch item {
            case .new(let d):
                SpanEditor(start: d.start, end: d.end, month: store.month) { title, s, e in
                    store.addSpan(CalSpan(author: .kitty, title: title, startDay: s, endDay: e))
                }
            case .edit(let s):
                // 月视图上的删 = 整条拿掉；要只去掉某一天得进那天的日视图
                SpanEditor(start: s.startDay, end: s.endDay, month: store.month, editing: s) { title, a, b in
                    store.updateSpan(s, title: title, start: a, end: b)
                } onDelete: {
                    store.deleteSpan(s)
                }
            }
        }
    }

    // 头部：July 2026 + 副标题 + ◀ ▶
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.month.monthLabel)
                        .font(Fonts.serif(40)).kerning(-0.5).foregroundColor(Ink.title)
                    Text(store.month.yearLabel)
                        .font(Fonts.serif(18)).foregroundColor(Ink.titleDim)
                }
                // 这行字平时写「tap a day to open it」，正在拉数据时写 syncing…，
                // 拉挂了写 couldn't load · tap to retry —— 三种文案都在 store 里，这儿只负责显示。
                // contentShape 不画任何东西，只是让这行字能被点到；没挂的时候 retry() 什么都不做
                Text(store.subtitle)
                    .font(Fonts.script(14)).foregroundColor(Ink.sub)
                    .contentShape(Rectangle())
                    .onTapGesture { store.retry() }
            }
            Spacer()
            HStack(spacing: 0) {
                navButton("◀", lead: 14) { store.month = store.month.previous }
                navButton("▶", lead: 5, trail: 18) { store.month = store.month.next }
            }.padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)   // 相对安全区；设计稿绝对值为屏幕顶 58
    }

    private func navButton(_ s: String, lead: CGFloat, trail: CGFloat = 0,
                           _ act: @escaping () -> Void) -> some View {
        Text(s).font(Fonts.mono(8)).foregroundColor(Ink.title)
            .frame(width: 22, height: 19)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Paper.navBorder, lineWidth: 1.3))
            .frame(height: 44, alignment: .top)   // 往下多长出来的一截透明命中区，描边还钉在原来的位置
            .padding(.leading, lead)              // 往左借的空白；▶ 这 5 就是原来两颗之间的间距
            .padding(.trailing, trail)            // ▶ 往右借页边那 18，不然它只有 27 宽，比 ◀ 窄一截
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .padding(.trailing, -trail)           // 借来的宽度还给布局，两颗玻璃的位置纹丝不动
    }

    // 日历卡片：边框 1.4 #E4C2C6，圆角 5，硬阴影 offset(3,3)
    private var card: some View {
        VStack(spacing: 0) {
            weekdayRow
            grid
            legend
        }
        .background(Paper.card)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Paper.border, lineWidth: 1.4))
        .background(RoundedRectangle(cornerRadius: 5).fill(Paper.cardShadow).offset(x: 3, y: 3))
    }

    // 一行 7 格，行数按月算。手势挂在这一层：格子自己不接触摸，落点由坐标反算，
    // 免得子视图手势优先把父层盖掉（日视图便签那场就是栽在这儿）
    private var grid: some View {
        VStack(spacing: 0) {
            // 行数按月算，4 到 6 行都可能（2027-02 是 4 行，2026-08 是 6 行）。
            // 多出来的高度由 body 里那个 Spacer(minLength: 0) 让位，格高 cellH 一点不动
            ForEach(0..<store.month.weekRows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(row * 7 + col)
                    }
                }
                .overlay(Rectangle().frame(height: 0.8).foregroundColor(Paper.gridLine), alignment: .bottom)
            }
        }
        .coordinateSpace(.named("monthGrid"))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridW = $0 }
        .contentShape(Rectangle())
        .gesture(pickGesture)
    }

    // 按住一格 0.3 秒 → 起点亮起，手指不松横着拖 → 沿路长出预览带 → 松手弹编辑器。
    // 没按够时间、也没怎么动 = 一次普通的点，照旧打开日视图
    private var pickGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("monthGrid"))
            .onChanged { v in
                if pressAt == nil {
                    pressAt = v.startLocation
                    lastAt = v.startLocation
                    pressDay = dayAt(v.startLocation)
                    handled = false
                    armLongPress(v.startLocation)
                }
                lastAt = v.location
                if !handled, pickFrom != nil, let d = dayAt(v.location), d != pickTo {
                    pickTo = d
                    pickTick += 1
                }
            }
            .onEnded { v in
                let range = pickRange
                let moved = hypot(v.location.x - v.startLocation.x,
                                  v.location.y - v.startLocation.y)
                let tapped = pressDay
                let taken = handled
                pressAt = nil; lastAt = nil; pressDay = nil
                pickFrom = nil; pickTo = nil; handled = false

                if taken { return }          // 已经弹了编辑器，这一按到此为止
                if let r = range {
                    sheet = .new(SpanDraft(start: r.lowerBound, end: r.upperBound))
                } else if let d = tapped, moved < 12 {
                    selectedDay = d
                    openDay(d)
                }
            }
    }

    /// 0.3 秒后回来看一眼：手指还在、还没动、落点是本月的日子 →
    /// 砸在已有色带上就是要改那条，砸在空白处才是拉新的一条
    private func armLongPress(_ at: CGPoint) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard pressAt == at, pickFrom == nil, !handled, let d = pressDay, let l = lastAt,
                  hypot(l.x - at.x, l.y - at.y) < 14 else { return }
            if let s = bandHit(at) {
                handled = true
                sheet = .edit(s)
                pickTick += 1
                return
            }
            pickFrom = d
            pickTo = d
            pickTick += 1
        }
    }

    /// 这一按砸在哪条色带上（上下各放 5pt 容差），没砸中返回 nil
    private func bandHit(_ p: CGPoint) -> CalSpan? {
        guard let d = dayAt(p) else { return nil }
        let inCell = p.y - CGFloat(Int(p.y / cellH)) * cellH
        for (i, s) in store.spans(covering: d).prefix(2).enumerated() {
            let top = 17 + CGFloat(i) * 36
            if inCell >= top - 5 && inCell <= top + 38 { return s }
        }
        return nil
    }

    /// 网格坐标 → 日号。列宽均分、行高 cellH，落在上月/下月的格子上返回 nil
    private func dayAt(_ p: CGPoint) -> Int? {
        guard gridW > 0 else { return nil }
        let col = Int(p.x / (gridW / 7))
        let row = Int(p.y / cellH)
        guard (0..<7).contains(col), (0..<store.month.weekRows).contains(row) else { return nil }
        let n = row * 7 + col - store.month.leadingBlanks + 1
        return (1...store.month.daysInMonth).contains(n) ? n : nil
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(CalMonth.weekdayHeaders, id: \.self) { w in
                Text(w).font(Fonts.mono(7.5)).kerning(0.4).foregroundColor(Ink.title)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .overlay(Rectangle().frame(width: 0.8).foregroundColor(Paper.gridLine), alignment: .trailing)
            }
        }
        .overlay(Rectangle().frame(height: 1.3).foregroundColor(Paper.border), alignment: .bottom)
    }

    // 单个日期格
    private func dayCell(_ index: Int) -> some View {
        let m = store.month
        let n = index - m.leadingBlanks + 1
        let dim = n < 1 || n > m.daysInMonth
        // 灰格上写的是上月月末/下月月初的日号，天数按真实月份算（原来写死 30 和 31）
        let disp = dim ? (n < 1 ? m.previous.daysInMonth + n : n - m.daysInMonth) : n
        // 显示的不是本月时 todayInMonth 是 nil，日期数字就不会被误染成粉的
        let isToday = !dim && n == m.todayInMonth

        return ZStack(alignment: .topLeading) {
            GridPaperTexture()
            if dim { DimHatch() }
            // 跨天安排色带：满格宽、不切角、横着贯穿（生理期条那套圆角出血是它自己的语言，不混用）。
            // 一格最多摞两条：88 － 起点 17 － 两条 33 － 间距 3 刚好塞得下，再多的被 clipped 裁掉
            if !dim {
                let bands = store.spans(covering: n)
                ForEach(Array(bands.prefix(2).enumerated()), id: \.element.id) { i, s in
                    band(s.author).frame(height: 33).offset(y: 17 + CGFloat(i) * 36)
                }
            }
            // 手指正拖到这一格
            if !dim, let r = pickRange, r.contains(n) {
                Paper.blockPick.frame(height: 33).offset(y: 17)
            }
            // 下面这一片样板装饰（划掉线、空相框、分类贴纸）还是只在 2026 年 7 月出现，
            // 翻到别的月一个都不冒出来。
            // 生理期不算在里头了 —— 它现在是后端那条 event_type == "period" 的跨天事件算出来的，
            // 哪个月有就哪个月画，一个月里有两段也画得出来
            if !dim, let pr = store.periodRange(covering: n) { periodBand(n, in: pr) }
            // 今天日期印章（46×46 居中 top26，.5，-7°）——按定稿拿掉。
            // 工程没有版本库，留个注释在这儿，想要回来把这四行放开就行；
            // 今天照样认得出：日期数字是粉的（Ink.today）
            // if isToday {
            //     StampView(sticker: .todayStamp, size: 46, rotation: -7, opacity: 0.5)
            //         .frame(maxWidth: .infinity).offset(y: 26)
            // }
            if !dim && store.isStampDay(n) {   // 特殊日子爱心章（纪念日/生日/约定之夜）：44×44 top30 .72 -16°
                StampView(sticker: .annivStamp, size: 44, rotation: -16, opacity: 0.72)
                    .frame(maxWidth: .infinity).offset(y: 30)
            }
            if !dim && n == selectedDay {   // 选中粉圈 32×22 at (-2,-1)
                Sticker.dateCircle.image.resizable()
                    .frame(width: 32, height: 22).offset(x: -2, y: -1)
            }
            VStack(alignment: .leading, spacing: 1) {   // 数字 + 事件
                Text("\(disp)")
                    .font(Fonts.mono(10.5))
                    .foregroundColor(dim ? Ink.dimDay : (isToday ? Ink.today : Ink.title))
                    .padding(.leading, 2)
                if !dim {
                    // 跨天安排的标题只写在第一天，后面几天光有色带
                    ForEach(store.spans(covering: n).filter { $0.days.lowerBound == n }) { s in
                        Fonts.handText(s.title, s.author, small: true)
                            .font(Fonts.hand(8,s.author, month: true))
                            .foregroundColor(ink(s.author))
                            .padding(.leading, 2)
                    }
                    ForEach(store.events(on: n).filter { !$0.isAutoSuggestion }) { ev in
                        Fonts.handText(ev.title, ev.author, small: true)
                            .font(Fonts.hand(8,ev.author, month: true))
                            .foregroundColor(ink(ev.author))
                            .padding(.leading, 2)
                    }
                }
            }
            .padding(.top, 3).padding(.horizontal, 3)
            // 空相框（4号）：34×53 右2 底1 -4°，胶带 23×11.5 右上角 +24°
            if !dim && m.isSampleMonth && SampleData.photoDays.contains(n) {
                VStack { Spacer()
                    HStack { Spacer()
                        InstaxEmptyFrame(width: 34, height: 53, rotation: -4)
                            .overlay(alignment: .topTrailing) {
                                GinghamTape(width: 23, height: 11.5, rotation: 24).offset(x: 8, y: -5)
                            }
                            .padding(.trailing, 2).padding(.bottom, 1)
                    }
                }
            }
            // 分类贴纸（左下角）：11/20 行李箱、17 咖啡杯
            if !dim && m.isSampleMonth && SampleData.monthCellCategories.contains(n),
               let cat = SampleData.category[n] {
                VStack { Spacer()
                    HStack {
                        CategorySticker(category: cat, large: false)
                            .padding(.leading, 2).padding(.bottom, 2)
                        Spacer()
                    }
                }
            }
            // 贴纸缩略：压在左上角日期数字右边的空白上。
            // 右下角被 NEW!! 和空相框占了，左下角是分类贴纸，中间是印章，只剩这块没人用。
            if !dim {
                let thumbs = store.recentPlaced(on: n, limit: 3)
                if !thumbs.isEmpty {
                    // 跟分类贴纸同一个位置：左下角。那天要是本来就有分类贴纸，
                    // 两摞压在一起也是拼贴该有的样子
                    VStack { Spacer(); HStack {
                        PlacedThumbs(items: thumbs, library: monthLibrary)
                        Spacer()
                    } }
                }
            }
            // 感叹号（右下角）：AI 侧在这一页改过东西、用户还没点进去看
            if !dim && store.hasUnseen(n) {
                VStack { Spacer()
                    HStack { Spacer()
                        NewBadge().padding(.trailing, 3).padding(.bottom, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellH)
        .clipped()
        .overlay(Rectangle().frame(width: 0.8).foregroundColor(Paper.gridLine), alignment: .trailing)
        // 触摸不在这儿收，统一交给 grid 那层的 pickGesture 按坐标反算
        .allowsHitTesting(false)
    }

    // 生理期胶带条：高18 top2；起点右端平、终点左端平、中段两端出血。
    // r 是这一天所属的那一段（跨月的已经在 materialize 里裁到本月内了），
    // 首末两天的圆角照它算，不再认那个写死的 13...18
    private func periodBand(_ n: Int, in r: ClosedRange<Int>) -> some View {
        let first = n == r.lowerBound
        let last = n == r.upperBound
        return Paper.period
            .frame(height: 18)
            // 只圆朝外那一侧。用 RoundedRectangle 会把四个角一起圆掉，
            // 于是首日的右边、末日的左边也各缺一块，粉带就断在那两处
            .clipShape(.rect(topLeadingRadius: first ? 9 : 0,
                             bottomLeadingRadius: first ? 9 : 0,
                             bottomTrailingRadius: last ? 9 : 0,
                             topTrailingRadius: last ? 9 : 0))
            .padding(.leading, first ? 3 : -1)
            .padding(.trailing, last ? 3 : -1)
            .offset(y: 2)
    }

    private var legend: some View {
        HStack(spacing: 9) {
            legendItem(Ink.kitty, "USER"); legendItem(Ink.master, "ASSISTANT"); legendItem(Ink.system, "AUTO")
            Spacer()
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 5).fill(Paper.period).frame(width: 17, height: 9)
                Text("生理期").font(Fonts.body(7.5)).foregroundColor(Ink.legend.opacity(0.82))
            }
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 12))
    }

    private func legendItem(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 11, height: 3)
            Text(label).font(Fonts.mono(7.5)).foregroundColor(Ink.legend)
        }
    }

    private func ink(_ a: Author) -> Color {
        switch a { case .kitty: return Ink.kitty; case .master: return Ink.master; case .system: return Ink.system }
    }

    /// 跨天色带的底色，跟笔迹一样按人分
    private func band(_ a: Author) -> Color {
        switch a {
        case .kitty:  return Paper.block
        case .master: return Paper.blockAssistant
        case .system: return Paper.blockAuto
        }
    }
}

/// 松手后要弹编辑器，sheet(item:) 得有个 Identifiable 的东西装起止日
struct SpanDraft: Identifiable {
    let id = UUID()
    var start: Int
    var end: Int
}

/// 新建和改用同一个弹窗，合成一个 item 走一条 sheet，免得两个 sheet 抢
enum SpanSheet: Identifiable {
    case new(SpanDraft)
    case edit(CalSpan)
    var id: String {
        switch self {
        case .new(let d):  return "new-\(d.id)"
        case .edit(let s): return "edit-\(s.id)"
        }
    }
}

// 非本月：45° 斜线填充
struct DimHatch: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width { path.move(to: .init(x: x, y: size.height)); path.addLine(to: .init(x: x + size.height, y: 0)); x += 5 }
            ctx.stroke(path, with: .color(Color(hex: 0xD6A8AC, alpha: 0.16)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}
