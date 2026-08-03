import SwiftUI

// ============================================================
// EventEditor.swift — 新建 / 改一条日程。名字、全天开关、起止、删掉。
// 纯白底，不铺方格纸。editing == nil 是新建；否则预填那条并多出删除入口。
// 开关是从 我另一个 app SettingsKit 移植的 PinkToggle。
// ============================================================

struct EventEditor: View {
    let day: Int
    /// 这条日程属于哪个月，标题文案要用
    let month: CalMonth
    var editing: CalEvent? = nil
    var onCommit: (String, Date, Date, Bool) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool
    @State private var confirmDelete = false
    // 两颗胶囊各管各的开关。曾经共用一个 picking 枚举，点「到」会先把「从」那个轮子弹出来——
    // 同一层挂两个 popover，共享状态时 SwiftUI 会认错人。拆成两个独立 Bool 就不串了
    @State private var pickStart = false
    @State private var pickEnd = false

    init(day: Int,
         month: CalMonth,
         editing: CalEvent? = nil,
         onCommit: @escaping (String, Date, Date, Bool) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.day = day
        self.month = month
        self.editing = editing
        self.onCommit = onCommit
        self.onDelete = onDelete
        if let e = editing {
            _title = State(initialValue: e.title)
            _allDay = State(initialValue: e.isAllDay)
            if e.isAllDay {
                _start = State(initialValue: CalendarStore.time(0, 0))
                _end   = State(initialValue: CalendarStore.time(23, 59))
            } else {
                _start = State(initialValue: CalendarStore.time(e.startHour, e.startMinute))
                let endM = e.startHour * 60 + e.startMinute + e.durationMinutes
                _end = State(initialValue: CalendarStore.time(min(23, endM / 60), endM % 60))
            }
        } else {
            _title = State(initialValue: UserDefaults.standard.string(forKey: "prefill") ?? "")
            _allDay = State(initialValue: false)
            _start = State(initialValue: CalendarStore.time(9))
            _end   = State(initialValue: CalendarStore.time(10))
        }
    }

    private var isEditing: Bool { editing != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var sheetHeight: CGFloat {
        // 固定高度：全天只是把时间行锁灰，不抽走，弹窗不跟着跳
        isEditing ? 278 : 272
    }
    /// 谁写的用谁的笔迹；新建的算用户自己写的
    private var pen: Author { editing?.author ?? .kitty }

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.ignoresSafeArea()   // 纯白，不铺方格纸

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(month.chineseMonth)\(day)日").font(Fonts.body(19)).foregroundColor(Ink.title)
                    Text(isEditing ? "edit" : "new plan")
                        .font(Fonts.script(14)).foregroundColor(Ink.sub)
                    Spacer()
                    if isEditing { deleteButton }
                }

                TextField("", text: $title, prompt:
                    Text("what's new").font(Fonts.script(21)).foregroundColor(Ink.dimDay))
                    .font(Fonts.hand(21, pen))
                    .kerning(Fonts.kern(pen))
                    .foregroundColor(pen == .master ? Ink.noteMaster : Ink.noteKitty)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .padding(.top, 16)
                    .padding(.bottom, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Paper.border).frame(height: 1.3)
                    }

                HStack(spacing: 12) {
                    Text("全天").font(Fonts.body(15)).foregroundColor(Ink.kitty)
                    PinkToggle(on: $allDay.animation(.spring(response: 0.34, dampingFraction: 0.78)))
                        .onChange(of: allDay) { _, isOn in
                            if isOn {                       // 拉满一整天；关掉后就停在这两个值
                                start = CalendarStore.time(0, 0)
                                end   = CalendarStore.time(23, 59)
                            }
                        }
                    Spacer()
                }
                .padding(.top, 18)

                // 从 [ ] 到 [ ]，并成一行；24 小时制跟时间轴对齐，不用 AM/PM
                // 切到全天时这一行留在原地褪成灰、锁掉交互，不做进出动画，免得布局跳
                HStack(spacing: 8) {
                    Text("从").font(Fonts.body(15))
                        .foregroundColor(allDay ? Ink.dimDay : Ink.kitty)
                    timeCapsule($start, open: $pickStart)
                    Text("到").font(Fonts.body(15))
                        .foregroundColor(allDay ? Ink.dimDay : Ink.kitty)
                    timeCapsule($end, open: $pickEnd)
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
                .grayscale(allDay ? 1 : 0)
                .opacity(allDay ? 0.45 : 1)
                .disabled(allDay)
                .animation(.easeOut(duration: 0.22), value: allDay)

                Spacer(minLength: 14)

                VStack(spacing: 9) {
                    Button {
                        onCommit(title, CalendarStore.clamp(start), CalendarStore.clamp(end), allDay)
                        dismiss()
                    } label: {
                        // 淡粉底 + 深粉字：比实心 #D4737F 柔和，可读性反而更好
                        Text("save")
                            .font(Fonts.mono(14)).kerning(0.8)
                            .foregroundColor(canSave ? Ink.noteKitty : Ink.dimDay)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 16)
                                .fill(canSave ? Paper.fab : Color(hex: 0xF7EFF0)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .animation(.bouncy(duration: 0.3), value: canSave)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .onAppear { if !isEditing { titleFocused = true } }
    }

    // 系统 compact DatePicker 那颗胶囊的灰底是 iOS 自己画的，盖不住，
    // 只能 colorMultiply 压暗成粉灰 —— 想要真浅粉只能自己画一颗，
    // 滚轮塞进 popover 里，点开才出来（跟跨天编辑器那两颗日期胶囊同一套）
    // 淡粉胶囊 + 文楷时间，点一下轮子从正上方开出来。
    // arrowEdge 指的是箭头长在 popover 自己哪条边上：箭头在底边 = 弹窗挂在胶囊上面。
    // 轮子压到 128 高是为了留得下——胶囊上方就那么点地方，装不下系统会自己翻到侧边去
    private func timeCapsule(_ value: Binding<Date>, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue = true } label: {
            Text(Self.hhmm(value.wrappedValue))
                .font(Fonts.body(15))
                .foregroundColor(Ink.noteKitty)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Paper.capsule))
        }
        .buttonStyle(.plain)
        .popover(isPresented: open, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            DatePicker("", selection: value, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                // 轮盘也钉死上海。少了这句，轮盘按设备时区显示、
                // 而 CalendarStore.span 按上海读，人在国外时选 14:30 会存成别的钟点
                .environment(\.timeZone, CalMonth.zone)
                .frame(width: 210, height: 128)
                .presentationCompactAdaptation(.popover)   // 不加这句 iPhone 上会摊成半屏 sheet
        }
    }

    private static func hhmm(_ d: Date) -> String {
        let c = CalMonth.calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // 删除要点两下：第一下变成 confirm，避免手滑
    private var deleteButton: some View {
        Button {
            if confirmDelete {
                onDelete?()
                dismiss()
            } else {
                withAnimation(.bouncy(duration: 0.34, extraBounce: 0.25)) { confirmDelete = true }
            }
        } label: {
            Text(confirmDelete ? "confirm" : "delete")
                .font(Fonts.mono(11)).kerning(0.5)
                .foregroundColor(confirmDelete ? .white : Ink.kitty)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(
                    Capsule().fill(confirmDelete ? Ink.kitty : Color.clear)
                        .overlay(Capsule().stroke(Paper.border, lineWidth: confirmDelete ? 0 : 1.2))
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview("新建") {
    EventEditor(day: 17, month: .sample) { _, _, _, _ in }
}
