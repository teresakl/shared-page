import SwiftUI
import PhotosUI

// ============================================================
// DayView.swift — 1b 日视图。时间轴 06:00–23:00，每小时 52pt。
// 便签/贴纸/相框都是绝对定位（ZStack topLeading + offset），
// 坐标为设计定稿值，禁止改动。
// 年月由 store.month 提供，坐标定稿值一律未动。
// ============================================================

struct DayView: View {
    @Environment(CalendarStore.self) private var store
    @Binding var day: Int
    var backToMonth: () -> Void
    @State private var fabOpen = ProcessInfo.processInfo.arguments.contains("-fabOpen")
    @State private var showEditor = ProcessInfo.processInfo.arguments.contains("-editor")
    @State private var editingEvent: CalEvent? = nil
    @State private var editingSpan: CalSpan? = nil
    @State private var hapticTick = 0
    @State private var editingNoteID: String? = nil
    @State private var scrollY: CGFloat = 0
    @State private var trayOpen = ProcessInfo.processInfo.arguments.contains("-tray")
    @State private var library = StickerLibrary()
    /// 时间轴可视区在窗口里的位置，把抽屉交出来的 .global 落点换算成内容坐标要用
    @State private var timelineFrame: CGRect = .zero
    @State private var selectedPlacedID: UUID? = nil
    @State private var showPhotoPicker = false
    @State private var photoPick: PhotosPickerItem? = nil
    @State private var draggingNoteID: String? = nil
    /// 正在编辑模式里的那张便签：浮着、右上角挂着叉、可以反复拖。
    /// 长按进去，点别处才出来 —— 松手不落纸
    @State private var activeNoteID: String? = nil
    /// 进入编辑模式之后累计挪了多少。松手只是把这一段加进来，不落库
    @State private var activeDY: CGFloat = 0
    @State private var dragDY: CGFloat = 0
    /// 手上正按着纸面上的某样东西（贴纸/照片/便签）。按着的时候把滚动关掉，
    /// 否则 ScrollView 会在半路把手势抢走，拖到一半就断
    @State private var busy = false
    /// 日期条滚到哪一格（dayKey）。选中日变化时把那格带回条子中间
    @State private var stripPos: String? = nil

    private let rowH: CGFloat = 52
    private let firstHour = 6, lastHour = 23
    private var timelineH: CGFloat { 10 + CGFloat(lastHour - firstHour + 1) * rowH + 96 }

    var body: some View {
        VStack(spacing: 0) {
            backHeader
            weekStrip.padding(.horizontal, 10).padding(.top, 10)
            titleRow
            allDayRows
            timeline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) { fab }
        .onAppear {
            store.markSeen(day)     // 点进来就算看过了，月视图那两个感叹号跟着消失
            // 调试：-editFirst 直接进当天第一条的编辑态
            if ProcessInfo.processInfo.arguments.contains("-editFirst"),
               let first = store.events(on: day).first {
                openEditor(first)
            }
            if ProcessInfo.processInfo.arguments.contains("-blankNote") { stickBlankNote() }
        }
        // 在日视图里顺着周条换到别天，也算看过了那天
        .onChange(of: day) { old, d in
            // 切天之前把编辑模式里那张先落库 —— 不然那段没写下去的位移就丢了。
            // commitActiveNote 读的是当前 day，所以这里只能靠 activeNoteID 还没清来兜，
            // 保险起见直接按旧的那天落
            commitActiveNote(on: old)
            store.markSeen(d)
        }
        // 气泡和贴纸栏的开合不再影响选中 —— 编辑状态由长按进、点别处出，
        // 跟这两个抽屉没关系了
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTick)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPick, matching: .images)
        .onChange(of: photoPick) { _, v in
            guard let v else { return }
            Task {
                defer { photoPick = nil }
                guard let data = try? await v.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                placePhoto(img)
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { editingEvent = nil }) {
            EventEditor(day: day, month: store.month, editing: editingEvent) { title, s, e, allDay in
                if let ev = editingEvent {
                    store.update(ev, on: day, title: title, start: s, end: e, allDay: allDay)
                } else {
                    store.add(CalendarStore.makeEvent(title: title, start: s, end: e,
                                                      author: .kitty, allDay: allDay), on: day)
                }
            } onDelete: {
                if let ev = editingEvent { store.delete(ev, on: day) }
            }
            // id 换成 String 了（本地是 local_xxx，后端是 cal_xxx），直接用就行；
            // "new" 是新建时的兜底，两种前缀都撞不上它
            .id(editingEvent?.id ?? "new")
        }
        // 这里的删除只挖掉当天：挖头挖尾就缩一天，挖中间裂成两段
        .sheet(item: $editingSpan) { s in
            SpanEditor(start: s.startDay, end: s.endDay, month: store.month, editing: s) { title, a, b in
                store.updateSpan(s, title: title, start: a, end: b)
            } onDelete: {
                store.removeDay(day, from: s)
            }
        }

    }

    // ‹ July
    private var backHeader: some View {
        HStack {
            Button(action: { commitActiveNote(); finishNote(); backToMonth() }) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("‹").font(Fonts.serif(22)).foregroundColor(Ink.kitty)
                    Text(store.month.monthLabel).font(Fonts.serif(26)).kerning(-0.3).foregroundColor(Ink.title)
                }
            }.buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    // 日期条：一条可以左右拖着滑的日期流（拖条本身，不是划一下切页）。
    // 以本月为锚往前后各铺十周，非本月的日子淡色但点得动，点了顺势翻月。
    // 每格的字母/字号/粉圈/间距全是原定稿值；格宽 = 原来七格均分的 382/7
    private static let stripCellW: CGFloat = 382.0 / 7

    private struct StripDay: Identifiable {
        let id: String          // "2026-08-02"，也当滚动定位的锚
        let month: CalMonth
        let day: Int
        let letterIdx: Int      // weekLetters 的下标（周一起）
    }

    /// 条子的日期带在进程里只生成这一次：今天往前 200 天、往后 400 天，共 600 格。
    /// 翻月绝不重建 —— 跨月只许颜色渐变（旧月暗下去、新月亮起来），
    /// 条子本身一格都不许挪。LazyHStack 只画看得见的几格，600 格不吃力
    private static let stripRange: [StripDay] = {
        let cal = CalMonth.calendar
        guard let start = cal.date(byAdding: .day, value: -200, to: Date()) else { return [] }
        return (0..<600).compactMap { off in
            guard let dt = cal.date(byAdding: .day, value: off, to: start) else { return nil }
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: dt)
            guard let y = c.year, let mo = c.month, let d = c.day else { return nil }
            let m = CalMonth(year: y, month: mo)
            // weekday 1=周日…7=周六 → M T W T F S S（周一起）的下标
            return StripDay(id: m.dayKey(d), month: m, day: d,
                            letterIdx: ((c.weekday ?? 1) + 5) % 7)
        }
    }()

    private var weekStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Self.stripRange) { sd in stripCell(sd) }
            }
            .scrollTargetLayout()
        }
        // 横向 ScrollView 会贪婪吃掉纵向弹性空间，钉回原条子的固有高度
        //（字母 9 + spacing 5 + 数字区 28）
        .frame(height: 42)
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .scrollPosition(id: $stripPos, anchor: .center)
        // 只在进日视图这一下定位到选中日（不然条子停在两百天前）。
        // 之后条子归用户的手指管：点了不回中、换天不回中
        .onAppear { stripPos = store.month.dayKey(day) }
    }

    @ViewBuilder private func stripCell(_ sd: StripDay) -> some View {
        let isCur = sd.month == store.month
        let selected = isCur && sd.day == day
        VStack(spacing: 5) {
            Text(CalMonth.weekLetters[sd.letterIdx])
                .font(Fonts.mono(7.5)).kerning(0.4)
                .foregroundColor(Ink.subLight)
            ZStack {
                if selected {
                    Sticker.dateCircle.image.resizable()
                        .frame(width: 36, height: 26).offset(x: -3, y: 1)
                }
                // 今天的日期印章（32×32 -8° .55）——跟月视图那枚一起拿掉（07-31）。
                // 今天照样认得出：日期数字是粉的
                Text("\(sd.day)")
                    .font(Fonts.mono(13))
                    .foregroundColor(!isCur ? Ink.dimDay
                                     : (sd.day == sd.month.todayInMonth ? Ink.today : Ink.title))
            }
            .frame(width: 30, height: 28)
        }
        .frame(width: Self.stripCellW)
        .contentShape(Rectangle())
        // 跨月那一下只有颜色在渐变（isCur 翻转），格子不挪窝
        .animation(.easeInOut(duration: 0.22), value: isCur)
        .onTapGesture {
            commitActiveNote()
            finishNote()
            if sd.month != store.month { store.month = sd.month }
            day = sd.day
            fabOpen = false
            hapticTick += 1
        }
    }

    // 7月17日 Friday（顶部 1.3pt 分隔线；中文星期不显示）
    private var titleRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Paper.border).frame(height: 1.3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(store.month.chineseMonth)\(day)日").font(Fonts.body(20)).foregroundColor(Ink.title)
                Text(store.month.englishWeekday(of: day) + (day == store.month.todayInMonth ? " · today" : ""))
                    .font(Fonts.script(13)).foregroundColor(Ink.subLight)
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private var dayEvents: [CalEvent] { store.events(on: day) }

    /// 抽屉交出来的是窗口坐标；减掉时间轴可视区的原点、加回滚动量，才是内容坐标
    private func timelinePoint(from global: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, global.x - timelineFrame.minX), 402),
                y: min(max(0, global.y - timelineFrame.minY + scrollY), timelineH))
    }

    private func dropSticker(_ item: StickerLibrary.Item, at global: CGPoint) {
        let p = timelinePoint(from: global)
        store.place(PlacedItem(kind: .sticker, stickerID: item.id,
                               x: p.x, y: p.y), on: day)
        hapticTick += 1
    }

    /// 照片是一次性的：存进沙盒拿到文件名就直接贴在当前视口中间，不进抽屉
    private func placePhoto(_ image: UIImage) {
        guard let file = store.importPhoto(image) else { return }
        let midY = scrollY + (timelineFrame.height > 0 ? timelineFrame.height / 2 : 200)
        store.place(PlacedItem(kind: .photo, photoFile: file, x: 201, y: midY), on: day)
        hapticTick += 1
    }

    /// 收起 FAB。贴纸栏是从贴纸球身上长出来的，得先让它缩回去，再收球，
    /// 否则球都没了栏还悬在半空
    private func closeFab() {
        guard trayOpen else {
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.26)) { fabOpen = false }
            return
        }
        withAnimation(.bouncy(duration: 0.28, extraBounce: 0.06)) { trayOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.26)) { fabOpen = false }
        }
    }

    /// emoji 不烤不入库，落在当前视口中间，之后拖缩转跟贴纸一模一样
    private func placeEmoji(_ e: String) {
        let midY = scrollY + (timelineFrame.height > 0 ? timelineFrame.height / 2 : 200)
        store.place(PlacedItem(kind: .emoji, emoji: e, x: 201, y: midY), on: day)
        hapticTick += 1
    }

    private func openEditor(_ ev: CalEvent?) {
        editingEvent = ev
        hapticTick += 1
        showEditor = true
    }

    // 跨天安排：这天是第几天／一共几天，长按改
    private func spanRow(_ s: CalSpan) -> some View {
        HStack { VStack(alignment: .leading, spacing: 2) {
            Fonts.handText(s.title, s.author).font(Fonts.hand(16, s.author)).foregroundColor(Ink.title)
            Text("DAY \(s.index(of: day))/\(s.length) · \(s.author.rawValue)")
                .font(Fonts.mono(7)).kerning(0.4).foregroundColor(ink(s.author))
        }; Spacer() }
        .padding(EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9))
        .background(blockBg(s.author))
        .overlay(Rectangle().frame(width: 2).foregroundColor(ink(s.author)), alignment: .leading)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.32) {
            hapticTick += 1
            editingSpan = s
        }
    }

    @ViewBuilder private var allDayRows: some View {
        let all = dayEvents.filter(\.isAllDay)
        let spans = store.spans(covering: day)
        if !all.isEmpty || !spans.isEmpty {
            VStack(spacing: 5) {
                ForEach(spans) { s in spanRow(s) }
                ForEach(all) { ev in
                    HStack { VStack(alignment: .leading, spacing: 2) {
                        Fonts.handText(ev.title, ev.author).font(Fonts.hand(16, ev.author)).foregroundColor(Ink.title)
                        Text("ALL DAY · \(ev.author.rawValue)")
                            .font(Fonts.mono(7)).kerning(0.4).foregroundColor(ink(ev.author))
                    }; Spacer() }
                    .padding(EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9))
                    .background(blockBg(ev.author))
                    .overlay(Rectangle().frame(width: 2).foregroundColor(ink(ev.author)), alignment: .leading)
                    .overlay(alignment: .topTrailing) {   // 纪念日爱心章 48×48 (right6, top-8) -16° .8
                        if store.isStampDay(day) {
                            StampView(sticker: .annivStamp, size: 48, rotation: -16, opacity: 0.8)
                                .offset(x: -6, y: -8)
                        }
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.32) { openEditor(ev) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
    }

    // —— 时间轴 ————————————————————————————————
    private var timeline: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                GridPaperTexture().frame(height: timelineH)
                ForEach(firstHour...lastHour, id: \.self) { h in hourRow(h) }
                notesLayer
                stickersLayer
                PlacedLayer(day: day, library: library,
                            onBusyChange: { on in
                                busy = on
                                // 这里不收气泡。08-02 拆掉 editable 闸门之后
                                // 已经没有「栏一收正按着的那张当场失效」这个问题了，
                                // 但收气泡会把贴纸栏一起收走，手指还按着的时候没必要动它
                            },
                            // 一直可编辑。防误触交给长按本身 —— 贴纸的 bodyDrag 是
                            // 「按住 0.24 秒再拖」，快速划过去的手指赢不了这场竞争、会落给滚动。
                            // 原来靠「气泡或贴纸栏展开」当闸门，那道门现在是多余的
                            editable: true,
                            contentHeight: timelineH, selectedID: $selectedPlacedID)
            }
            .frame(height: timelineH)
            .contentShape(Rectangle())
            // 点纸面别处 = 收笔 + 取消选中 + 收起气泡。
            // 收起不能靠盖一层全屏透明视图去接点击——那层会把底下所有长按拖动一起吃掉
            .onTapGesture {
                finishNote()
                commitActiveNote()
                selectedPlacedID = nil
                if fabOpen { closeFab() }
                // 真机踩的坑（8/2）：emoji 面板开着点纸面收不掉——收面板的链路
                // 只挂在收贴纸栏上。这里直接把第一响应者请下去，谁开的键盘都一起收
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            }
        }
        .scrollDisabled(busy)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, v in
            scrollY = v
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { timelineFrame = $0 }
        .padding(.top, 2)
    }

    /// 撕一张空白便签按在当前看得见的位置，直接开始写
    private func stickBlankNote() {
        let seed = UserDefaults.standard.string(forKey: "noteText") ?? ""
        let n = CalNote(author: .kitty,
                        text: NoteFit.truncate(seed, author: .kitty),
                        timestamp: CalendarStore.stamp(),
                        y: max(8, scrollY + 96))
        store.addNote(n, on: day)
        editingNoteID = n.id
        activeNoteID = n.id          // 刚撕下来就是编辑状态，能改字也能挪
        activeDY = 0
        hapticTick += 1
    }

    /// 收笔。这一下才第一次把这张纸送上服务器 —— 打字全程不发网络。
    /// 07-31 之前这里会把空白的直接丢掉，现在不丢了：撕下来的纸就留着，
    /// 想撕掉得长按浮起来点右上角那个叉
    private func finishNote() {
        if let id = editingNoteID {
            store.commitNote(id: id, on: day)
        }
        editingNoteID = nil
    }

    private func yOf(hour: Int, minute: Int = 0) -> CGFloat {
        10 + CGFloat(hour - firstHour) * rowH + CGFloat(minute) / 60 * rowH
    }

    @ViewBuilder private func hourRow(_ h: Int) -> some View {
        let y = yOf(hour: h)
        // 小时横线：x 52 → 右-12
        Rectangle().fill(Paper.gridLine).frame(height: 1)
            .padding(.leading, 52).padding(.trailing, 12)
            .offset(y: y)
        Text(String(format: "%02d:00", h))
            .font(Fonts.mono(8)).foregroundColor(Ink.hourLbl)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.white.opacity(0.9))
            .offset(x: 11, y: y - 6)
        ForEach(dayEvents.filter { !$0.isAllDay && $0.startHour == h }) { ev in
            eventBlock(ev)
                .offset(x: 56, y: yOf(hour: h, minute: ev.startMinute))
                .onLongPressGesture(minimumDuration: 0.32) { openEditor(ev) }
        }
    }

    // 事件块：x56 → 右-16；高 = max(34, dur/60*52-3)；左描边 2.5
    private func eventBlock(_ ev: CalEvent) -> some View {
        let h = max(34, CGFloat(ev.durationMinutes) / 60 * rowH - 3)
        let endM = ev.startHour * 60 + ev.startMinute + ev.durationMinutes
        // 「今天以前的打勾」按定稿去掉，跟月视图那条红笔划掉线一起退役。
        // 红勾素材 Sticker.checkMark 还在 Theme 里，真要回来的时候不用重找
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

    // 留言便签：top = 34 + i×116；kitty 靠右(右14)，master 靠左(左58)
    // 留言便签：top = 34 + i×116；kitty 靠右(右14)，master 靠左(左58)
    @ViewBuilder private var notesLayer: some View {
        let notes = store.notes(on: day)
        ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
            let baseY = note.y ?? (34 + CGFloat(i) * 116)
            let dragging = draggingNoteID == note.id
            let pendingDelete = activeNoteID == note.id
            TornNoteView(note: note,
                         index: i,
                         linkedTitle: linkedTitle(of: note),
                         lifted: dragging || pendingDelete,
                         editing: editingNoteID == note.id,
                         onTextChange: { store.setNoteText(note, on: day, text: $0) })
                // 长按浮起来 → 右上角那个叉。点叉才真撕掉
                .overlay(alignment: .topTrailing) {
                    if pendingDelete {
                        Text("✕")
                            .font(Fonts.mono(11))
                            .foregroundColor(Ink.kitty)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white))
                            .overlay(Circle().stroke(Paper.border, lineWidth: 1.2))
                            .shadow(color: Color(hex: 0x96787D, alpha: 0.28), radius: 2, y: 1)
                            .offset(x: 6, y: -6)
                            .contentShape(Circle())
                            .onTapGesture {
                                activeNoteID = nil          // 直接退出，不 commit —— 纸都撕了还落什么位
                                activeDY = 0
                                store.deleteNote(note, on: day)
                                hapticTick += 1
                            }
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .offset(x: note.author == .master ? 58 : 402 - 14 - 174,
                        y: baseY + (pendingDelete ? activeDY : 0) + (dragging ? dragDY : 0))
                .zIndex(dragging || pendingDelete ? 20 : 0)
                // 双击 = 给 AI 侧的便签点赞，再双击一次收回来。
                // 只挂在 AI 侧那边：自己的纸上还有单击改字和拖着挪位置，三个抢一根手指准打架
                .gesture(TapGesture(count: 2).onEnded {
                    store.toggleLike(note, on: day)
                    hapticTick += 1
                }, isEnabled: note.author == .master)
                // 单击什么都不进 —— 只把别处正开着的编辑状态收掉。
                // 08-02 之前单击会直接冒出文字输入框，那算误触，
                // 现在唯一的入口是长按 0.5 秒（见 noteDrag）
                .onTapGesture {
                    if activeNoteID != note.id {
                        commitActiveNote()
                        finishNote()
                    }
                }

                // 拖动也只限自己的；AI 侧的便签贴在哪儿由那一侧定
                .gesture(noteDrag(note, baseY: baseY), isEnabled: note.author == .kitty)
                .animation(.spring(response: 0.32, dampingFraction: 0.74), value: dragging)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pendingDelete)
        }
    }

    /// 长按进编辑模式，之后随便拖 —— 抄贴纸那边的写法（PlacedLayer.bodyDrag）。
    ///
    /// 关键是那个 minimumDuration：还没进编辑模式要按住 0.5 秒，
    /// 进去之后是 0，手指一碰就跟着走。外面裹着 LongPressGesture 是为了赢下手势竞争 ——
    /// 裸的 DragGesture 会被 ScrollView 在半路抢走，结果页面在滚、纸没动。
    ///
    /// 松手【不落纸】：只是把这一程的位移累进 activeDY，人还留在编辑模式里，
    /// 想再挪几次都行。只有点别处才真的写库并退出（commitActiveNote）
    private func noteDrag(_ note: CalNote, baseY: CGFloat) -> some Gesture {
        let active = activeNoteID == note.id
        return LongPressGesture(minimumDuration: active ? 0 : 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 手指刚落下就会经过这里，长按时间此刻还没走完。
                    // 快速点击不能激活便签，也不能提前关掉时间轴滚动。
                    break
                case .second(true, let d):
                    busy = true                       // 长按确认后，这根手指只归这张纸
                    if activeNoteID != note.id {
                        commitActiveNote()            // 上一张先落下去
                        finishNote()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            activeNoteID = note.id
                            activeDY = 0
                        }
                        // 自己写的那些顺手把文字光标也给上 —— 一次长按拿到全套：
                        // 浮起来、能拖、能改字、右上角有叉。AI 侧的只能拖不能改字
                        if note.author == .kitty { editingNoteID = note.id }
                        hapticTick += 1
                    }
                    guard let d else { break }
                    if draggingNoteID != note.id { draggingNoteID = note.id }
                    dragDY = d.translation.height
                default:
                    break
                }
            }
            .onEnded { value in
                busy = false
                guard case .second(true, let d) = value, let d else {
                    draggingNoteID = nil; dragDY = 0; return
                }
                activeDY += d.translation.height      // 只是累计，不写库
                draggingNoteID = nil
                dragDY = 0
            }
    }

    /// 点别处 = 落纸。把编辑模式里累计的位移一次性写下去，然后退出
    private func commitActiveNote(on which: Int? = nil) {
        let day = which ?? self.day
        guard let id = activeNoteID else { return }
        defer {
            activeNoteID = nil
            activeDY = 0
        }
        guard activeDY != 0,
              let n = store.notes(on: day).first(where: { $0.id == id }),
              let idx = store.notes(on: day).firstIndex(where: { $0.id == id })
        else { return }
        let baseY = n.y ?? (34 + CGFloat(idx) * 116)
        let finalY = min(max(0, baseY + activeDY), timelineH - 96)
        store.placeNote(n, on: day, y: finalY, linkedTo: eventUnder(y: finalY + 42)?.id)
        hapticTick += 1
    }

    /// 贴在哪条日程上：只看中心点的纵坐标落没落进这条日程的时间段里。
    /// 横向不管 —— 贴在时间轴哪一侧都算，事件的「范围」就是它那段时间。
    private func eventUnder(y: CGFloat) -> CalEvent? {
        dayEvents.first { ev in
            guard !ev.isAllDay else { return false }
            let top = yOf(hour: ev.startHour, minute: ev.startMinute)
            let bottom = top + max(34, CGFloat(ev.durationMinutes) / 60 * rowH - 3)
            return y >= top && y <= bottom
        }
    }

    private func linkedTitle(of note: CalNote) -> String? {
        guard let id = note.linkedEventID else { return nil }
        return dayEvents.first { $0.id == id }?.title
    }


    @ViewBuilder private var stickersLayer: some View {
        // 分类贴纸：travel (64,388) / movie (64,396) / food (64,390)
        if store.month.isSampleMonth, let cat = SampleData.category[day] {
            let pos: CGPoint = cat == .travel ? .init(x: 64, y: 388)
                             : cat == .movie  ? .init(x: 64, y: 396)
                             : .init(x: 64, y: 390)
            CategorySticker(category: cat, large: true).offset(x: pos.x, y: pos.y)
        }
        // 猫贴纸 92×98 (右18, top340) -6°
        if store.month.isSampleMonth && SampleData.catStickerDays.contains(day) {
            Sticker.catSticker.image.resizable().scaledToFit()
                .frame(width: 92, height: 98)
                .rotationEffect(.degrees(-6))
                .offset(x: 402 - 18 - 92, y: 340)
        }
        // 空拍立得 92×143 (62,806) -3.5°，胶带 46×23 (-16,-8) -28°
        if store.month.isSampleMonth && SampleData.dayPhotoDays.contains(day) {
            InstaxEmptyFrame(width: 92, height: 143, rotation: -3.5)
                .overlay(alignment: .topLeading) {
                    GinghamTape(width: 46, height: 23, rotation: -28).offset(x: -16, y: -8)
                }
                .offset(x: 62, y: 806)
        }
        // 这一天还空着。跨天安排也算数，不然顶上挂着「出差 DAY 2/3」底下还喊空
        if dayEvents.isEmpty && store.notes(on: day).isEmpty && store.spans(covering: day).isEmpty {
            VStack(spacing: 2) {
                Text("这一天还空着").font(Fonts.body(17))
                Text("nothing here yet").font(Fonts.script(13))
            }
            .foregroundColor(Color(hex: 0x86646A, alpha: 0.42))
            .frame(width: 402)
            .offset(y: 110)
        }
    }

    // 右下 +：50pt 圆 #F4D9DE；点开弹三个球
    // 从上到下：写留言 / 贴贴纸 / 加日程（最常用的贴着拇指）
    private static let fabItems: [(id: String, icon: String)] = [
        ("note",    "ic-note"),
        ("sticker", "ic-sticker"),
        ("photo",   "ic-photo"),
        ("event",   "ic-event"),
    ]
    private static let fabShadow = Color(hex: 0xC4969E, alpha: 0.22)

    private var fab: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(Self.fabItems.enumerated()), id: \.offset) { i, item in
              HStack(spacing: 9) {
                if item.id == "sticker" {
                    StickerStrip(library: library,
                                 onDropSticker: { it, p in dropSticker(it, at: p) },
                                 open: trayOpen,
                                 onStickerRemoved: {
                                     // 抽屉里删掉的贴纸，已经贴在日历上的那些也得跟着收拾
                                     store.prunePlacedStickers(keeping: Set(library.all.map(\.id)))
                                 },
                                 onPickEmoji: { placeEmoji($0) })
                        .frame(width: 268, alignment: .trailing)
                        .allowsHitTesting(trayOpen)
                }
                // 展开：靠 FAB 的先蹦；收起：最远的先撤
                let delay = fabOpen
                    ? Double(Self.fabItems.count - 1 - i) * 0.055
                    : Double(i) * 0.03
                Button {
                    // 贴纸球不收 FAB：条子就是从这颗球左边抽出来的，收了 FAB 条子也没了
                    if item.id == "sticker" {
                        withAnimation(.bouncy(duration: 0.34, extraBounce: 0.1)) { trayOpen.toggle() }
                        return
                    }
                    // 照片球也不收 FAB：相册是全屏盖上来的，收了用户也看不见，
                    // 而选完回来照片就落在纸上——气泡还开着才拖得动它。
                    // 顺带，中途取消相册也能站在原地，不用重新点开气泡
                    if item.id == "photo" {
                        showPhotoPicker = true
                        return
                    }
                    closeFab()
                    if item.id == "note" { stickBlankNote() }    // 写便签
                    if item.id == "event" { openEditor(nil) }
                } label: {
                    Image(item.icon).renderingMode(.template)
                        .resizable().scaledToFit()
                        .frame(width: 21, height: 21)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Paper.fab))
                        .shadow(color: Self.fabShadow, radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .scaleEffect(fabOpen ? 1 : 0.25, anchor: .bottom)
                .opacity(fabOpen ? 1 : 0)
                .offset(y: fabOpen ? 0 : 66)
                .animation(.bouncy(duration: 0.46, extraBounce: 0.3).delay(delay), value: fabOpen)
              }
            }
            Button {
                if fabOpen { closeFab() }
                else { withAnimation(.bouncy(duration: 0.42, extraBounce: 0.26)) { fabOpen = true } }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 25, weight: .light))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(fabOpen ? 135 : 0))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Paper.fab))
                    .shadow(color: Self.fabShadow, radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .scaleEffect(fabOpen ? 0.93 : 1)
        }
        .padding(.trailing, 14).padding(.bottom, 24)
    }

    private func ink(_ a: Author) -> Color {
        switch a { case .kitty: return Ink.kitty; case .master: return Ink.master; case .system: return Ink.system }
    }

    /// 事件块底色跟着作者走：用户侧粉 / AI 侧薄荷绿 / AUTO 灰
    private func blockBg(_ a: Author) -> Color {
        switch a {
        case .kitty:  return Paper.eventBg
        case .master: return Paper.eventBgAssistant
        case .system: return Paper.eventBgAuto
        }
    }
}
