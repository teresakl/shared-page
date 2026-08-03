import SwiftUI

// ============================================================
// PageRender.swift — 阶段五：整页图给 AI 侧看。
//
// 把某一天的日视图渲染成 PNG 传到网关（POST /pages/{date}/render），
// AI 侧的 calendar 工具用 see 动作取走。三样东西都在这个文件里：
//
//   · DayPageContent  静态复刻日视图那一页（titleRow + 全天行 + 时间轴），
//                     所有坐标/字号/颜色照抄 DayView 的定稿值，一个没改。
//                     没有手势、没有滚动 —— 只为渲染而生
//   · PageCrop        上下空白时段裁掉：同样的 token 换更宽的画面，小字更清楚
//   · PageSync        「这天动过」的记号 + 渲染 + 上传。
//                     退回月视图 / 切后台时把动过的那几天悄悄传上去，
//                     失败不重试不打扰，记号留着等下一次时机
//
// 触发规矩（方案 §6.2）：只有真的动过的那天才渲染上传；
// -sample 模式一个字节都不发。
// ============================================================

// —— 裁剪：内容在哪几个小时之间 ————————————————————
struct PageCrop {
    var top: CGFloat
    var height: CGFloat

    /// 跟 DayView 同一把尺子：rowH 52，时间轴 06:00–23:00，内容高 1042
    static let rowH: CGFloat = 52
    static let firstHour = 6, lastHour = 23
    static var timelineH: CGFloat { 10 + CGFloat(lastHour - firstHour + 1) * rowH + 96 }

    static func yOf(hour: Int, minute: Int = 0) -> CGFloat {
        10 + CGFloat(hour - firstHour) * rowH + CGFloat(minute) / 60 * rowH
    }

    /// 按这一天真正有东西的纵向范围算：贴齐小时线，留出标签，
    /// 空的日子给一小段（"这一天还空着"那几行字所在的位置）
    static func compute(events: [CalEvent], notes: [CalNote], placed: [PlacedItem]) -> PageCrop {
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        func cover(_ a: CGFloat, _ b: CGFloat) {
            minY = min(minY, a); maxY = max(maxY, b)
        }
        for ev in events where !ev.isAllDay {
            let top = yOf(hour: ev.startHour, minute: ev.startMinute)
            cover(top, top + max(34, CGFloat(ev.durationMinutes) / 60 * rowH - 3))
        }
        for (i, n) in notes.enumerated() {
            let baseY = n.y ?? (34 + CGFloat(i) * 116)
            cover(baseY - 16, baseY + 110)      // 胶带往上探 11，纸高约 90 + 影子
        }
        for item in placed {
            // 旋转过的用半对角线兜住，怎么转都在圈里
            let art = PlacedArt.resolve(item, library: nil)
            let r = hypot(art.size.width, art.size.height) / 2 * item.scale
            cover(item.y - r, item.y + r)
        }
        if minY > maxY { cover(96, 176) }       // 空白日：那两行"这一天还空着"在 y110 附近

        // 贴齐小时线：上边退到覆盖 minY 的那条线再让出标签，下边推到盖住 maxY 的下一条线
        let hTop = max(firstHour, min(lastHour, firstHour + Int(floor((minY - 10) / rowH))))
        let hBot = max(firstHour, min(lastHour, firstHour + Int(ceil((maxY - 10) / rowH))))
        let top = max(0, yOf(hour: hTop) - 8)
        let bottom = min(timelineH, yOf(hour: hBot) + 12)
        return PageCrop(top: top, height: max(rowH, bottom - top))
    }
}

// —— PlacedArt.resolve 的无抽屉版重载 ————————————————
// 裁剪只要尺寸不要图；真渲染时传真抽屉
extension PlacedArt {
    static func resolve(_ item: PlacedItem, library: StickerLibrary?) -> PlacedArt {
        guard let library else {
            switch item.kind {
            case .emoji:
                return PlacedArt(image: nil, size: CGSize(width: PlacedMetrics.emojiBase,
                                                          height: PlacedMetrics.emojiBase))
            case .photo:
                return PlacedArt(image: nil,
                                 size: CGSize(width: PlacedMetrics.base,
                                              height: PlacedMetrics.base * PlacedMetrics.instaxAspect))
            case .sticker:
                return PlacedArt(image: nil, size: CGSize(width: PlacedMetrics.base,
                                                          height: PlacedMetrics.base))
            }
        }
        return resolve(item, library: library)
    }
}

// —— 已贴上去的东西，静态版 ————————————————————————
// 画法逐行照抄 PlacedItemView（影子公式、拍立得窗口比例都一样），只是没有手势
private struct PlacedStaticView: View {
    var item: PlacedItem
    var art: PlacedArt

    var body: some View {
        artView
            .frame(width: art.size.width, height: art.size.height)
            .shadow(color: Color(hex: 0x96787D, alpha: 0.3),
                    radius: 2.5 / max(item.scale, 0.01),
                    x: shadowOffset.width, y: shadowOffset.height)
            .rotationEffect(.degrees(item.rotation))
            .scaleEffect(item.scale)
    }

    @ViewBuilder private var artView: some View {
        switch item.kind {
        case .sticker:
            if let img = art.image {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Paper.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        case .photo:
            photoInFrame
        case .emoji:
            if let img = art.image {
                Image(uiImage: img).resizable().scaledToFit()
            }
        }
    }

    private var photoInFrame: some View {
        let w = art.size.width, h = art.size.height
        return ZStack(alignment: .topLeading) {
            Group {
                if let img = art.image {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Paper.instaxFill
                }
            }
            .frame(width: w * PlacedMetrics.winW, height: h * PlacedMetrics.winH)
            .clipped()
            .offset(x: w * PlacedMetrics.winInsetX, y: h * PlacedMetrics.winInsetTop)
            Sticker.photoFrame.image.resizable().frame(width: w, height: h)
        }
    }

    private var shadowOffset: CGSize {
        let ox: CGFloat = 1.5, oy: CGFloat = 2
        let r = -item.rotation * .pi / 180
        let c = CGFloat(cos(r)), s = CGFloat(sin(r))
        let k = max(item.scale, 0.01)
        return CGSize(width: (ox * c - oy * s) / k, height: (ox * s + oy * c) / k)
    }
}

// —— 那一页本身 ————————————————————————————————
struct DayPageContent: View {
    let month: CalMonth
    let day: Int
    let events: [CalEvent]
    let notes: [CalNote]
    let spans: [CalSpan]
    let placed: [PlacedItem]
    let library: StickerLibrary
    let crop: PageCrop

    private let rowH = PageCrop.rowH
    private let firstHour = PageCrop.firstHour, lastHour = PageCrop.lastHour
    private var timelineH: CGFloat { PageCrop.timelineH }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            allDayRows
            timeline
                .padding(.top, 2)
        }
        .padding(.bottom, 8)
        .frame(width: 402)
        .background(Color.white)
    }

    // 7月17日 Friday —— DayView.titleRow 的定稿值
    private var titleRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Paper.border).frame(height: 1.3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(month.chineseMonth)\(day)日").font(Fonts.body(20)).foregroundColor(Ink.title)
                Text(month.englishWeekday(of: day) + (day == month.todayInMonth ? " · today" : ""))
                    .font(Fonts.script(13)).foregroundColor(Ink.subLight)
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var stampDay: Bool { events.contains { $0.isSpecialDay } }

    @ViewBuilder private var allDayRows: some View {
        let all = events.filter(\.isAllDay)
        if !all.isEmpty || !spans.isEmpty {
            VStack(spacing: 5) {
                ForEach(spans) { s in
                    HStack { VStack(alignment: .leading, spacing: 2) {
                        Fonts.handText(s.title, s.author).font(Fonts.hand(16, s.author)).foregroundColor(Ink.title)
                        Text("DAY \(s.index(of: day))/\(s.length) · \(s.author.rawValue)")
                            .font(Fonts.mono(7)).kerning(0.4).foregroundColor(ink(s.author))
                    }; Spacer() }
                    .padding(EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9))
                    .background(blockBg(s.author))
                    .overlay(Rectangle().frame(width: 2).foregroundColor(ink(s.author)), alignment: .leading)
                }
                ForEach(all) { ev in
                    HStack { VStack(alignment: .leading, spacing: 2) {
                        Fonts.handText(ev.title, ev.author).font(Fonts.hand(16, ev.author)).foregroundColor(Ink.title)
                        Text("ALL DAY · \(ev.author.rawValue)")
                            .font(Fonts.mono(7)).kerning(0.4).foregroundColor(ink(ev.author))
                    }; Spacer() }
                    .padding(EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9))
                    .background(blockBg(ev.author))
                    .overlay(Rectangle().frame(width: 2).foregroundColor(ink(ev.author)), alignment: .leading)
                    .overlay(alignment: .topTrailing) {
                        if stampDay {
                            StampView(sticker: .annivStamp, size: 48, rotation: -16, opacity: 0.8)
                                .offset(x: -6, y: -8)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
    }

    // 时间轴：内容按整高排好，再按 crop 往上挪、裁掉窗口外的
    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            GridPaperTexture().frame(width: 402, height: timelineH)
            ForEach(firstHour...lastHour, id: \.self) { h in hourRow(h) }
            notesLayer
            emptyState
            placedLayer
        }
        .frame(width: 402, height: timelineH, alignment: .topLeading)
        .offset(y: -crop.top)
        .frame(width: 402, height: crop.height, alignment: .top)
        .clipped()
    }

    private func yOf(hour: Int, minute: Int = 0) -> CGFloat {
        PageCrop.yOf(hour: hour, minute: minute)
    }

    @ViewBuilder private func hourRow(_ h: Int) -> some View {
        let y = yOf(hour: h)
        Rectangle().fill(Paper.gridLine).frame(height: 1)
            .padding(.leading, 52).padding(.trailing, 12)
            .offset(y: y)
        Text(String(format: "%02d:00", h))
            .font(Fonts.mono(8)).foregroundColor(Ink.hourLbl)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.white.opacity(0.9))
            .offset(x: 11, y: y - 6)
        ForEach(events.filter { !$0.isAllDay && $0.startHour == h }) { ev in
            eventBlock(ev)
                .offset(x: 56, y: yOf(hour: h, minute: ev.startMinute))
        }
    }

    private func eventBlock(_ ev: CalEvent) -> some View {
        let h = max(34, CGFloat(ev.durationMinutes) / 60 * rowH - 3)
        let endM = ev.startHour * 60 + ev.startMinute + ev.durationMinutes
        return VStack(alignment: .leading, spacing: 0) {
            Fonts.handText(ev.title, ev.author).font(Fonts.hand(17, ev.author)).foregroundColor(Ink.title)
            Spacer(minLength: 0)
            Text("\(ev.timeLabel)–\(String(format: "%02d:%02d", endM / 60, endM % 60)) · \(ev.author.rawValue)")
                .font(Fonts.mono(7)).kerning(0.4).foregroundColor(ink(ev.author))
        }
        .padding(EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9))
        .frame(width: 402 - 56 - 16, height: h, alignment: .topLeading)
        .background(blockBg(ev.author))
        .overlay(Rectangle().frame(width: 2.5).foregroundColor(ink(ev.author)), alignment: .leading)
    }

    @ViewBuilder private var notesLayer: some View {
        ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
            TornNoteView(note: note, index: i, linkedTitle: linkedTitle(of: note))
                .offset(x: note.author == .master ? 58 : 402 - 14 - 174,
                        y: note.y ?? (34 + CGFloat(i) * 116))
        }
    }

    private func linkedTitle(of note: CalNote) -> String? {
        guard let id = note.linkedEventID else { return nil }
        return events.first { $0.id == id }?.title
    }

    @ViewBuilder private var emptyState: some View {
        if events.isEmpty && notes.isEmpty && spans.isEmpty {
            VStack(spacing: 2) {
                Text("这一天还空着").font(Fonts.body(17))
                Text("nothing here yet").font(Fonts.script(13))
            }
            .foregroundColor(Color(hex: 0x86646A, alpha: 0.42))
            .frame(width: 402)
            .offset(y: 110)
        }
    }

    @ViewBuilder private var placedLayer: some View {
        ForEach(placed) { item in
            let art = PlacedArt.resolve(item, library: library)
            PlacedStaticView(item: item, art: art)
                .offset(x: item.x - art.size.width / 2,
                        y: item.y - art.size.height / 2)
        }
    }

    private func ink(_ a: Author) -> Color {
        switch a { case .kitty: return Ink.kitty; case .master: return Ink.master; case .system: return Ink.system }
    }

    private func blockBg(_ a: Author) -> Color {
        switch a {
        case .kitty:  return Paper.eventBg
        case .master: return Paper.eventBgAssistant
        case .system: return Paper.eventBgAuto
        }
    }
}

// —— 渲染成 PNG ————————————————————————————————
enum PageRenderer {
    /// AI 侧收图长边上限 1568，页宽 402 × 1.5 = 603 正好贴着走（方案 §6.3 实测够清楚）
    static let scale: CGFloat = 1.5

    @MainActor
    static func render(store: CalendarStore, library: StickerLibrary,
                       month: CalMonth, day: Int) -> Data? {
        let events = store.events(in: month, on: day)
        let notes = store.notes(in: month, on: day)
        let spans = store.spans(in: month, covering: day)
        let placed = PlacedStore.shared.items(key: month.dayKey(day))
        let crop = PageCrop.compute(events: events, notes: notes, placed: placed)
        let page = DayPageContent(month: month, day: day,
                                  events: events, notes: notes, spans: spans,
                                  placed: placed, library: library, crop: crop)
        let renderer = ImageRenderer(content: page)
        renderer.scale = Self.scale
        renderer.proposedSize = ProposedViewSize(width: 402, height: nil)
        guard let ui = renderer.uiImage else { return nil }
        // 高度 ×1.5 常常不是整像素，ImageRenderer 的边缘半行要么黑（opaque）要么透明，
        // 两种都会在图的底边压出一条脏线。铺一层白底重画成实心图，边缘永远是白的
        let px = CGSize(width: ui.size.width * ui.scale, height: ui.size.height * ui.scale)
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1
        f.opaque = true
        let flat = UIGraphicsImageRenderer(size: px, format: f).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: px))
            ui.draw(in: CGRect(origin: .zero, size: px))
        }
        return flat.pngData()
    }
}

// ============================================================
// 调试探针：-pageProbe（可带 -probeDay 17）
// 启动后等这个月的数据落地，把选定那天渲染成 PNG 写进 Documents/page-probe.png，
// 用 simctl get_app_container 取出来看渲染质量。不发网络、不碰交互，
// 跟 BakeProbe（-bakeTest）同一个路数
// ============================================================
enum PageProbe {
    @MainActor
    static func runIfAsked(store: CalendarStore) {
        guard ProcessInfo.processInfo.arguments.contains("-pageProbe") else { return }
        Task { @MainActor in
            // 等 load 落地：-sample 秒过；真数据轮询到 loaded/failed 为止，最多 12 秒
            for _ in 0..<24 {
                if case .loaded = store.loadState { break }
                if case .failed = store.loadState { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let m = store.month
            let d = UserDefaults.standard.integer(forKey: "probeDay")
            let day = (1...m.daysInMonth).contains(d) ? d : (m.todayInMonth ?? 1)
            guard let png = PageRenderer.render(store: store, library: StickerLibrary(),
                                                month: m, day: day) else {
                print("[page] 渲染失败 \(m.key)-\(day)"); return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? png.write(to: docs.appendingPathComponent("page-probe.png"))
            print("[page] probe ok \(m.dayKey(day)) \(png.count) bytes")
            // -pageProbeUpload：再把这张走真实上传路（multipart 那段代码没有别的试法）。
            // 传的是用户真数据渲染出来的页，不是垃圾 —— 传上去就是第一张正式页面图
            if ProcessInfo.processInfo.arguments.contains("-pageProbeUpload") {
                do {
                    try await CalendarAPI.shared.uploadPage(day: m.dayKey(day), png: png)
                    print("[page] upload ok \(m.dayKey(day))")
                } catch {
                    print("[page] upload failed: \(error)")
                }
            }
        }
    }
}

// ============================================================
// 调试探针:-widgetProbe
// 把中号小组件卡片渲染成 PNG 写进 Documents/widget-probe.png —— 小组件
// 本体没法自动化截图,静态验收走这条(跟 -pageProbe 同一个路数)
// ============================================================
enum WidgetProbe {
    @MainActor
    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-widgetProbe") else { return }
        Task { @MainActor in
            let snap = await WidgetFetch.today()
            let card = WidgetMediumView(snap: snap)
                .frame(width: 364, height: 170)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            guard let png = renderer.uiImage?.pngData() else {
                print("[widget] 渲染失败"); return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? png.write(to: docs.appendingPathComponent("widget-probe.png"))
            print("[widget] probe ok \(png.count) bytes, \(snap.items.count) items")
        }
    }
}

// ============================================================
// PageSync — 哪几天动过、什么时候传
// ============================================================
final class PageSync {
    static let shared = PageSync()
    private init() {}

    /// 动过还没传上去的日子（"2026-08-02"）。纯内存不落盘（本地一份缓存都不留）；
    /// app 被杀就丢，代价只是那页的图旧一版，用户下次一动又会补上
    private var dirty: Set<String> = []
    private var uploading = false

    /// 每个写操作都来敲一下。-sample 模式一个都不记
    func markDirty(_ dayKey: String) {
        guard !AppMode.isSample else { return }
        dirty.insert(dayKey)
    }

    /// 退回月视图 / 切后台时喊一声：把动过的那几天渲染出来传上去。
    /// 渲染在主线程一次做完（一页几十毫秒），上传丢进后台任务；
    /// 传失败的记号留着，下一次时机自然会再试 —— 不打扰用户
    @MainActor
    func flush(store: CalendarStore) {
        guard !AppMode.isSample, !dirty.isEmpty, !uploading else { return }
        let batch = dirty
        let library = StickerLibrary()
        var pages: [(key: String, png: Data)] = []
        for key in batch {
            guard let (m, d) = CalMonth.parseDayKey(key) else {
                dirty.remove(key)               // 认不出来的键没法渲染，扔掉别让它卡住队伍
                continue
            }
            if let png = PageRenderer.render(store: store, library: library, month: m, day: d) {
                pages.append((key, png))
            }
        }
        guard !pages.isEmpty else { return }
        uploading = true
        // 切后台那一下系统只给几秒，报个后台任务把上传送完
        let bg = UIApplication.shared.beginBackgroundTask(withName: "calendar-page-upload")
        Task {
            for page in pages {
                do {
                    try await CalendarAPI.shared.uploadPage(day: page.key, png: page.png)
                    await MainActor.run { _ = self.dirty.remove(page.key) }
                } catch {
                    // 留着记号等下一次，不重试不提示 —— 页面图晚一版不是事故
                }
            }
            await MainActor.run { self.uploading = false }
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
    }
}
