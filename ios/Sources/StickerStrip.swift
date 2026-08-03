import SwiftUI
import PhotosUI

// ============================================================
// StickerStrip.swift — 从贴纸球向左抽出来的那一条。
//
// 不是底部面板：它挂在 FAB 的贴纸球那一行左边，宽度从 0 展开，
// 所以视觉上是「从球里拉出来的」。里面就是一排缩略图，横着滑看更多，
// 最左一格是导入口。没有标题、没有分栏、没有按钮胶囊。
//
// 横滑没用 ScrollView：它会跟缩略图上的 DragGesture 抢手势，连 simultaneousGesture
// 都压不住，结果就是滑不动。这里自己拿 offset 做滚动，一个手势按第一下的方向分流。
// 拎在手里的那张画在 .overlay 上并且 frame(0,0) 不占位，
// 这样它能画到条子外面（时间轴上），不会被容器裁掉。
// ============================================================

struct StickerStrip: View {

    var library: StickerLibrary
    /// 松手：哪张贴纸 + 手指的窗口坐标。松在条子自己身上算反悔，不回调
    var onDropSticker: (StickerLibrary.Item, CGPoint) -> Void
    var onDragStateChange: ((Bool) -> Void)? = nil
    /// 拉开状态。缩略图靠它做「从球里一个个弹出来」的错峰动画
    var open: Bool = true
    /// 从抽屉里真删掉一张之后：外面要顺手把已经贴出去的那些收拾掉
    var onStickerRemoved: (() -> Void)? = nil
    /// 挑了个 emoji。不烤不入库，直接贴
    var onPickEmoji: ((String) -> Void)? = nil

    /// 条子高度，跟 FAB 的球（50）差不多，摆一行不打架
    static let height: CGFloat = 62
    /// 落到时间轴上的长边基准。沿用日视图空相框 92×143 / 行李箱 92×84 的 92，
    /// 混在一张纸上大小才是一套的
    static let dropLongSide: CGFloat = 92

    static func dropSize(for image: UIImage) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        return w >= h
            ? CGSize(width: dropLongSide, height: dropLongSide * h / w)
            : CGSize(width: dropLongSide * w / h, height: dropLongSide)
    }

    private struct Lift {
        var item: StickerLibrary.Item
        var image: UIImage
        var size: CGSize
        var global: CGPoint
    }

    @State private var lifted: Lift? = nil
    @State private var stripFrame: CGRect = .zero
    @State private var pick: PhotosPickerItem? = nil
    /// 「＋」那格改成状态驱动弹相册 —— 内嵌式 PhotosPicker 按钮在真机上点了不弹
    /// （8/2 真机踩的坑），跟 DayView 照片球同一种挂法才稳
    @State private var showImport = false
    @State private var baking = false
    @State private var liftTick = 0
    @State private var dropTick = 0
    @State private var scrollX: CGFloat = 0
    @State private var scrollStart: CGFloat = 0
    /// 一次拖拽只认一种意图，第一下判完就不再改
    private enum Intent { case undecided, scroll, lift }
    @State private var intent: Intent = .undecided
    /// 长按亮出小叉的那张
    @State private var markedID: UUID? = nil
    @State private var emojiActive = false

    private let cell: CGFloat = 48

    /// 横滑不用 ScrollView：它会跟缩略图上的 DragGesture 抢手势，
    /// simultaneousGesture 也压不住（滑不动）。索性自己拿 offset 做，
    /// 一个手势按第一下的方向分流：横着走就滚，往上走就把贴纸拎出来。
    private var contentW: CGFloat {
        let n = CGFloat(library.all.count)
        return cell * (n + 2) + 8 * (n + 1) + 18    // 导入口 + emoji 格 + n 张 + 间距 + 内边距
    }
    private var minScrollX: CGFloat {
        min(0, (stripFrame.width > 0 ? stripFrame.width : 268) - contentW)
    }

    var body: some View {
        HStack(spacing: 8) {
            importCell
            emojiCell
            ForEach(Array(library.all.enumerated()), id: \.element.id) { i, item in
                thumb(item, index: i + 1)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .offset(x: scrollX)
        .frame(width: stripFrame.width > 0 ? stripFrame.width : 268,
               height: Self.height, alignment: .leading)
        .clipped()
        // 不给容器：没有底、没有描边。缩略图直接浮在时间轴上，各自带一点投影就够看清
        .overlay(alignment: .topLeading) { floating }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stripFrame = $0 }
        .sensoryFeedback(.impact(weight: .light), trigger: liftTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: dropTick)
        .onChange(of: open) { _, on in if !on { markedID = nil; emojiActive = false } }
        .onChange(of: pick) { _, v in
            guard let v else { return }
            Task { await importSticker(v) }
        }
        .photosPicker(isPresented: $showImport, selection: $pick,
                      matching: .images, photoLibrary: .shared())
    }

    // —— 一格贴纸 ————————————————————————————
    private func thumb(_ item: StickerLibrary.Item, index: Int) -> some View {
        Group {
            if let img = library.image(for: item) {
                Image(uiImage: img).resizable().scaledToFit()
                    .padding(4)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Paper.eventBg)
            }
        }
        .frame(width: cell, height: cell)
        // 摆得稍微歪一点，像随手压在盒子里的
        .rotationEffect(.degrees(index % 2 == 0 ? -3 : 2.5))
        .shadow(color: Color(hex: 0x96787D, alpha: 0.26), radius: 3, x: 1, y: 2)
        .opacity(lifted?.item.id == item.id ? 0.25 : 1)
        .overlay(alignment: .topTrailing) {
            if markedID == item.id { deleteBadge(item) }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(item))
        // 长按亮出小叉。内置那几张删不掉，就不给它亮
        .onLongPressGesture(minimumDuration: 0.32) {
            guard !item.isBuiltIn else { return }   // 内置的删不掉，静默无视
            withAnimation(.bouncy(duration: 0.34, extraBounce: 0.2)) { markedID = item.id }
            liftTick += 1
        }
        .modifier(PopIn(open: open, order: index + 1))
    }

    // —— 导入口：跟贴纸并排的一格虚线 ＋ ——————————————
    // 外观定稿没动。命中方式跟 emojiCell 完全同构（contentShape + onTapGesture）——
    // 8/2 真机实测：这个层级里 Button / 内嵌 PhotosPicker 都接不到点击（点了会穿到
    // 纸面把贴纸栏收掉），emoji 格的 onTapGesture 是唯一验证过能命中的写法
    private var importCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.3, dash: [3.5, 3]))
                .foregroundColor(Paper.border)
            if baking {
                ProgressView().scaleEffect(0.65).tint(Ink.kitty)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(Ink.kitty)
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !baking else { return }
            showImport = true
        }
        .simultaneousGesture(scrollOnlyGesture)     // 从「＋」起手也能滑
        .modifier(PopIn(open: open, order: 0))
    }

    /// 点一下就真删：文件、索引、抽屉里的位置一起没
    private func deleteBadge(_ item: StickerLibrary.Item) -> some View {
        Button {
            library.remove(item)
            markedID = nil
            onStickerRemoved?()
            dropTick += 1
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Ink.kitty))
                .overlay(Circle().stroke(.white, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }

    // —— 第二格：拉起系统 emoji 面板 ————————————————
    private var emojiCell: some View {
        ZStack {
            Text("😀").font(.system(size: 34))
                .shadow(color: Color(hex: 0x96787D, alpha: 0.26), radius: 3, x: 1, y: 2)
            // 零尺寸的透明输入框，只用来拿焦点把 emoji 键盘顶上来
            EmojiCatcher(active: $emojiActive) { e in
                onPickEmoji?(e)
                dropTick += 1
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { emojiActive = true }
        .simultaneousGesture(scrollOnlyGesture)
        .modifier(PopIn(open: open, order: 1))
    }

    // —— 拎在手里的那张 ————————————————————————
    @ViewBuilder private var floating: some View {
        if let d = lifted {
            let p = CGPoint(x: d.global.x - stripFrame.minX, y: d.global.y - stripFrame.minY)
            Image(uiImage: d.image).resizable().scaledToFit()
                .frame(width: d.size.width, height: d.size.height)
                .rotationEffect(.degrees(-4))
                .scaleEffect(1.06)                  // 拎在手里比落下去大一点
                // 这组影子照抄 TornNoteView.lifted，两种东西被拎起来时手感一致
                .shadow(color: Color(hex: 0x96787D, alpha: 0.42), radius: 8, x: 3, y: 7)
                .frame(width: 0, height: 0)         // 不占位，也就不会被条子的高度裁住
                .offset(x: p.x, y: p.y)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.55).combined(with: .opacity))
        }
    }

    private func dragGesture(_ item: StickerLibrary.Item) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if intent == .undecided {
                    if markedID != nil {
                        withAnimation(.easeOut(duration: 0.18)) { markedID = nil }
                    }
                    // 第一下定性质：偏横的算翻贴纸，偏竖的算把这张拎出来
                    if abs(v.translation.width) >= abs(v.translation.height) {
                        intent = .scroll
                        scrollStart = scrollX
                    } else if let img = library.image(for: item) {
                        intent = .lift
                        withAnimation(.bouncy(duration: 0.3, extraBounce: 0.22)) {
                            lifted = Lift(item: item, image: img,
                                          size: Self.dropSize(for: img), global: v.location)
                        }
                        liftTick += 1
                        onDragStateChange?(true)
                    }
                }
                switch intent {
                case .scroll:
                    scrollX = rubberBand(scrollStart + v.translation.width)
                case .lift:
                    lifted?.global = v.location
                case .undecided:
                    break
                }
            }
            .onEnded { v in
                defer { intent = .undecided }
                if intent == .scroll {
                    // 甩一下带点惯性，再弹回边界内
                    let target = scrollX + v.predictedEndTranslation.width * 0.35
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        scrollX = min(0, max(minScrollX, target))
                    }
                    return
                }
                guard let d = lifted else { return }
                lifted = nil
                onDragStateChange?(false)
                guard v.location.y < stripFrame.minY else { return }   // 松回条子上 = 反悔
                dropTick += 1
                onDropSticker(d.item, v.location)
            }
    }

    /// 只滚不拎，给导入口用
    private var scrollOnlyGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if intent == .undecided {
                    if markedID != nil {
                        withAnimation(.easeOut(duration: 0.18)) { markedID = nil }
                    }
                    intent = .scroll; scrollStart = scrollX
                }
                if intent == .scroll { scrollX = rubberBand(scrollStart + v.translation.width) }
            }
            .onEnded { v in
                defer { intent = .undecided }
                let target = scrollX + v.predictedEndTranslation.width * 0.35
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    scrollX = min(0, max(minScrollX, target))
                }
            }
    }

    /// 拖过头时带阻尼，松手弹回来
    private func rubberBand(_ x: CGFloat) -> CGFloat {
        if x > 0 { return x * 0.32 }
        if x < minScrollX { return minScrollX + (x - minScrollX) * 0.32 }
        return x
    }

    // —— 导入：烤一次存起来，之后每次用都是现成图 ————————
    private func importSticker(_ picked: PhotosPickerItem) async {
        baking = true
        defer { baking = false; pick = nil }
        guard let data = try? await picked.loadTransferable(type: Data.self),
              let src = UIImage(data: data) else { return }
        // 抠不出主体会退化成整张图套白边（模拟器必然如此），不提示，烤出什么是什么
        _ = await library.add(from: src)
    }
}


// 从贴纸球里一个个弹出来：越靠近球的越先蹦，收起时反过来。
// 参数跟 DayView 里那三颗球用的是同一组，弹性手感才是一套的。
private struct PopIn: ViewModifier {
    var open: Bool
    var order: Int
    func body(content: Content) -> some View {
        content
            .scaleEffect(open ? 1 : 0.55, anchor: .trailing)
            .opacity(open ? 1 : 0)
            .offset(x: open ? 0 : 26)          // 没拉开时缩回球那边
            // 这条不跟那四颗球用同一组参数：球是主动作可以蹦，
            // 贴纸栏一次弹五六个，回弹一大就整排在抖
            .animation(.bouncy(duration: 0.32, extraBounce: 0.08)
                .delay(open ? Double(order) * 0.028 : 0), value: open)
    }
}
