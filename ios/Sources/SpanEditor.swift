import SwiftUI

// ============================================================
// SpanEditor.swift — 新建 / 改一条跨天安排。名字、起止日、删掉。
// 跟 EventEditor 同一套版面（纯白底、手写标题、淡粉底按钮），
// 但没有钟点和全天开关 —— 跨天安排本来就只有「哪天到哪天」。
//
// 新建（editing == nil）：起止日由月视图那一拖定死，这里只填名字，不给日期行。
// 改（editing != nil）：日期行回来，起止都能调。
// 删除按钮的字随入口变 —— 月视图上是整条删，日视图上是把当天从这条里挖掉。
// ============================================================

struct SpanEditor: View {
    /// 这条跨天安排属于哪个月。标题文案和日号候选表都从它来
    let month: CalMonth
    var editing: CalSpan? = nil
    var onCommit: (String, Int, Int) -> Void
    var onDelete: (() -> Void)? = nil
    var deleteTitle: String = "delete"
    var deleteConfirm: String = "confirm"

    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    @State private var title: String
    @State private var start: Int
    @State private var end: Int
    @State private var confirmDelete = false

    init(start: Int, end: Int,
         month: CalMonth,
         editing: CalSpan? = nil,
         deleteTitle: String = "delete",
         deleteConfirm: String = "confirm",
         onCommit: @escaping (String, Int, Int) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.month = month
        self.editing = editing
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.deleteTitle = deleteTitle
        self.deleteConfirm = deleteConfirm
        _start = State(initialValue: min(start, end))
        _end   = State(initialValue: max(start, end))
        _title = State(initialValue: editing?.title ?? "")
    }

    private var isEditing: Bool { editing != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var span: ClosedRange<Int> { min(start, end)...max(start, end) }
    /// 谁写的用谁的笔迹；新建的算用户自己写的
    private var pen: Author { editing?.author ?? .kitty }

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(month.chineseMonth)\(span.lowerBound)日 – \(span.upperBound)日")
                        .font(Fonts.body(19)).foregroundColor(Ink.title)
                    Text(isEditing ? "edit" : "these days")
                        .font(Fonts.script(14)).foregroundColor(Ink.sub)
                    Spacer()
                    if isEditing { deleteButton }
                }

                TextField("", text: $title, prompt:
                    Text("what's on").font(Fonts.script(21)).foregroundColor(Ink.dimDay))
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

                // 改的时候才给这一行；新建是刚拖出来的，日子本来就是对的
                if isEditing {
                    HStack(spacing: 7) {
                        Text("从").font(Fonts.body(15)).foregroundColor(Ink.kitty)
                        dayPicker($start)
                        Text("日 到").font(Fonts.body(15)).foregroundColor(Ink.kitty)
                        dayPicker($end)
                        Text("日").font(Fonts.body(15)).foregroundColor(Ink.kitty)
                        Spacer(minLength: 0)
                        Text("共 \(span.count) 天")
                            .font(Fonts.body(13)).foregroundColor(Ink.sub)
                    }
                    .padding(.top, 18)
                }

                Spacer(minLength: 16)

                Button {
                    onCommit(title, span.lowerBound, span.upperBound)
                    dismiss()
                } label: {
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
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
        .presentationDetents([.height(isEditing ? 246 : 188)])
        .presentationDragIndicator(.visible)
        .onAppear { if !isEditing { titleFocused = true } }
    }

    /// 试过系统 compact date picker：它在 sheet 里会自动摊开一整块日历浮层，盖住半个屏幕，
    /// 而且中文格式是「2026年7月20日」，一行放不下两个。已回退，别再试。
    /// 这里是自绘：粉胶囊 + Space Mono 数字，点开只是一列日号
    private func dayPicker(_ value: Binding<Int>) -> some View {
        Menu {
            Picker("", selection: value) {
                ForEach(1...month.daysInMonth, id: \.self) { d in
                    Text("\(month.chineseMonth)\(d)日").tag(d)
                }
            }
        } label: {
            Text("\(value.wrappedValue)")
                .font(Fonts.body(15))
                .foregroundColor(Ink.noteKitty)
                .frame(minWidth: 24)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Paper.capsule))
        }
        .fixedSize()
    }

    // 删除要点两下，跟事件那边一个规矩
    private var deleteButton: some View {
        Button {
            if confirmDelete {
                onDelete?()
                dismiss()
            } else {
                withAnimation(.bouncy(duration: 0.34, extraBounce: 0.25)) { confirmDelete = true }
            }
        } label: {
            Text(confirmDelete ? deleteConfirm : deleteTitle)
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

#Preview("新建跨天") {
    SpanEditor(start: 20, end: 22, month: .sample) { _, _, _ in }
}
