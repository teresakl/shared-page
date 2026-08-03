import SwiftUI

// ============================================================
// PlacedLayer.swift — 时间轴上「已经贴上去的东西」这一层。
//
// 贴纸和照片贴到日视图之后，画出来、拖、缩放、转、撕掉，都归这个文件。
// 被 DayView 放进 timeline 的 ZStack，跟 notesLayer 平级；
// 月视图格子角上的极小缩略也在这里（PlacedThumbs）。
//
// 坐标：PlacedItem.x/y 是时间轴内容坐标里的中心点（画布宽 402，内容高 timelineH = 1042）。
// 定位沿用全工程的 ZStack(alignment: .topLeading) + offset 写法，没用 .position ——
// .position 会去要满宽，而这套版面里 402 是到处写死的常数，两者对不上。
//
// 数据层不在这个文件里：PlacedItem 模型、落盘、照片仓库、extension CalendarStore
// 全部归 PlacedItem.swift。这里只负责画出来和手势。
// ============================================================

// —— 定稿数值 ————————————————————————————————
enum PlacedMetrics {
    /// 新贴上去的东西长边锁 92 —— 日视图空相框就是 92 宽（StickerKit.InstaxEmptyFrame 定稿 92×143），
    /// CategorySticker 日视图的行李箱也是 92，混在一张纸上大小才是一套的
    static let base: CGFloat = 92
    /// 拍立得框长宽比，同上出处 143/92
    static let instaxAspect: CGFloat = 143.0 / 92.0

    /// 窗口透明区占框的比例，出处：StickerKit.InstaxEmptyFrame 顶部注释
    static let winInsetX: CGFloat = 0.107
    static let winInsetTop: CGFloat = 0.096
    static let winInsetBottom: CGFloat = 0.22
    /// 0.786 / 0.684 与 InstaxEmptyFrame 里写死的两个数完全一致
    static var winW: CGFloat { 1 - winInsetX * 2 }
    static var winH: CGFloat { 1 - winInsetTop - winInsetBottom }

    /// emoji 比贴纸小一号：贴纸是一整块图，emoji 更像随手戳的一个点
    static let emojiBase: CGFloat = 54
    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 3.0

    /// 右下角手柄直径。一半（13）同时当作「推到外框角上」的距离
    static let handleSize: CGFloat = 26
    /// 拖出画布就再也抓不回来了，四边各留这么宽不许越过
    static let edgeKeep: CGFloat = 16
}

// 一次取好，尺寸和渲染共用同一份，省得每帧 UIImage(named:) 走两遍
struct PlacedArt {
    var image: UIImage?
    var size: CGSize

    static func resolve(_ item: PlacedItem, library: StickerLibrary) -> PlacedArt {
        switch item.kind {
        case .emoji:
            guard let e = item.emoji, let img = EmojiRenderer.image(e) else {
                return PlacedArt(image: nil, size: CGSize(width: PlacedMetrics.emojiBase,
                                                         height: PlacedMetrics.emojiBase))
            }
            return PlacedArt(image: img, size: CGSize(width: PlacedMetrics.emojiBase,
                                                      height: PlacedMetrics.emojiBase))
        case .photo:
            return PlacedArt(image: item.photoFile.flatMap { PhotoVault.image($0) },
                             size: CGSize(width: PlacedMetrics.base,
                                          height: PlacedMetrics.base * PlacedMetrics.instaxAspect))
        case .sticker:
            guard let img = stickerImage(item, library: library) else {
                return PlacedArt(image: nil,
                                 size: CGSize(width: PlacedMetrics.base,
                                              height: PlacedMetrics.base))
            }
            // 长边锁 92，短边按原图比例走
            let w = max(img.size.width, 1), h = max(img.size.height, 1)
            let k = PlacedMetrics.base / max(w, h)
            return PlacedArt(image: img, size: CGSize(width: w * k, height: h * k))
        }
    }

    static func stickerImage(_ item: PlacedItem, library: StickerLibrary) -> UIImage? {
        guard let id = item.stickerID,
              let entry = library.all.first(where: { $0.id == id }) else { return nil }
        return library.image(for: entry)
    }
}

// —— 单个已放置元素 ————————————————————————————
struct PlacedItemView: View {
    var item: PlacedItem
    var art: PlacedArt
    var selected: Bool
    var onSelect: () -> Void
    /// 落点是新的中心（时间轴内容坐标，还没夹边界，夹在 PlacedLayer 那边做）
    var onMove: (CGPoint) -> Void
    var onTransform: (CGFloat, Double) -> Void
    var onTear: () -> Void
    /// 手上正按着这张：外面拿去把时间轴的滚动暂时关掉，免得跟 ScrollView 打架
    var onBusyChange: ((Bool) -> Void)? = nil
    /// 摆贴纸模式（贴纸栏拉开时）。关掉的时候这张就是纸的一部分，
    /// 一个手势都不认，触摸整个让给 ScrollView —— 手势之间也就没什么可抢的了
    var editable: Bool = true

    private struct Xform: Equatable { var scale: CGFloat; var rotation: Double }

    @State private var drag: CGSize = .zero
    @State private var lifted = false
    /// 手柄拖动过程中的实时值；松手写回 store 后清掉
    @State private var live: Xform? = nil
    /// 手柄按下那一刻的 scale/rotation，整段手势都以它为基准
    @State private var grabbed: Xform? = nil
    @State private var lastFingerAngle: Double? = nil
    @State private var tearing = false
    @State private var liftTick = 0
    @State private var tapTick = 0
    @State private var tearTick = 0

    /// 跟 DayView 的 FAB 一套阴影 #C4969E 0.22
    private static let handleShadow = Color(hex: 0xC4969E, alpha: 0.22)

    private var scale: CGFloat { live?.scale ?? item.scale }
    private var rotation: Double { live?.rotation ?? item.rotation }
    /// 拎起来整体涨 5%，跟 TornNoteView 的 lifted 一个手感
    private var lift: CGFloat { lifted ? 1.05 : 1 }
    /// 选中框和两个控件按这个反向抵消；撕掉时的塌缩不算进去，否则除数会归零
    private var chromeScale: CGFloat { max(scale * lift, 0.01) }

    var body: some View {
        artView
            .frame(width: art.size.width, height: art.size.height)
            .contentShape(Rectangle())
            // 白边已经烤进 PNG 了，浮起来靠这层影子。数值来自 TornNoteView 的 lifted
            .shadow(color: Color(hex: 0x96787D, alpha: lifted ? 0.42 : 0.3),
                    radius: (lifted ? 8 : 2.5) / chromeScale,
                    x: shadowOffset.width, y: shadowOffset.height)
            .overlay { if selected && editable && !tearing { marquee } }
            .overlay(alignment: .topTrailing) { if selected && editable && !tearing { tearButton } }
            .overlay(alignment: .bottomTrailing) { if selected && editable && !tearing { handle } }
            .rotationEffect(.degrees(tearing ? rotation + 34 : rotation))
            .scaleEffect(tearing ? scale * 0.06 : scale * lift)
            .opacity(tearing ? 0 : 1)
            .offset(drag)
            .gesture(bodyDrag, isEnabled: editable && !tearing && grabbed == nil)
            .allowsHitTesting(editable)
            .animation(.spring(response: 0.32, dampingFraction: 0.74), value: lifted)
            .animation(.easeIn(duration: 0.34), value: tearing)
            .animation(.bouncy(duration: 0.3, extraBounce: 0.2), value: selected)
            .sensoryFeedback(.impact(weight: .medium), trigger: liftTick)
            .sensoryFeedback(.impact(weight: .light), trigger: tapTick)
            .sensoryFeedback(.impact(weight: .heavy), trigger: tearTick)
    }

    // —— 画什么 ————————————————————————————
    @ViewBuilder private var artView: some View {
        switch item.kind {
        case .sticker:
            if let img = art.image {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                // 抽屉里那张被删了：留个虚位，好让人一眼看见并撕掉
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

    /// 照片塞进拍立得窗口再把框压上去。四个比例出处：StickerKit.InstaxEmptyFrame
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

    /// 光源在左上角是固定的，贴纸转了影子不该跟着转，先把外层的旋转反向转回去；
    /// 再除掉缩放，抵消外层 scaleEffect 对偏移量的放大，影子落在纸上始终一样远
    private var shadowOffset: CGSize {
        let ox: CGFloat = lifted ? 3 : 1.5
        let oy: CGFloat = lifted ? 7 : 2
        let r = -rotation * .pi / 180
        let c = CGFloat(cos(r)), s = CGFloat(sin(r))
        return CGSize(width: (ox * c - oy * s) / chromeScale,
                      height: (ox * s + oy * c) / chromeScale)
    }

    // —— 选中态的三件套 ————————————————————
    /// 线宽、虚线段、外扩都除掉缩放，放到 3 倍时也还是一根 1pt 细线
    private var marquee: some View {
        let k = 1 / chromeScale
        return RoundedRectangle(cornerRadius: 6 * k)
            .strokeBorder(Paper.navBorder,
                          style: StrokeStyle(lineWidth: k, dash: [4 * k, 3 * k]))
            .padding(-5 * k)
    }

    // 两个控件都反向抵消外层的旋转和缩放：缩到 0.35 时按钮会小得点不到，
    // 转 90° 时字是躺着的。anchor 钉在贴住元素的那个角上，位置才不会随缩放漂。
    private var tearButton: some View {
        let k = 1 / chromeScale
        return Button {
            // 进了编辑态本来就是有意为之，不再问第二遍
            tearTick += 1
            tearing = true
            // 等旋转缩小的动画走完再真的从 store 里拿掉
            Task { try? await Task.sleep(for: .seconds(0.34)); onTear() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(Circle().fill(Ink.kitty))
                .overlay(Circle().stroke(.white, lineWidth: 1.4))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .rotationEffect(.degrees(-rotation), anchor: .topTrailing)
        .scaleEffect(k, anchor: .topTrailing)
        // -27 = 胶囊高 22 + 虚线框外扩 5，正好悬在框的上沿
        .offset(x: 9 * k, y: -9 * k)
    }

    private var handle: some View {
        let k = 1 / chromeScale
        return ZStack {
            // 底色白的，不是粉的 —— 粉底上那个粉箭头看不清
            Circle().fill(Color.white)
                .overlay(Circle().stroke(Paper.navBorder, lineWidth: 1.2))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Ink.noteKitty)
        }
        .frame(width: PlacedMetrics.handleSize, height: PlacedMetrics.handleSize)
        .shadow(color: Self.handleShadow, radius: 3, y: 1)
        .contentShape(Circle())
        .rotationEffect(.degrees(-rotation), anchor: .bottomTrailing)
        .scaleEffect(k, anchor: .bottomTrailing)
        .offset(x: PlacedMetrics.handleSize / 2 * k, y: PlacedMetrics.handleSize / 2 * k)
        .gesture(handleDrag)
    }

    // —— 手势 ————————————————————————————
    // 两个手势都走 .global：这一层外面套了 rotationEffect / scaleEffect，
    // .local 的位移会被转进元素自己的斜坐标里，斜着贴的贴纸就会往歪的方向跑。
    /// 先按住、再拖。长按先赢下手势竞争，ScrollView 就不会在拖到一半把手势抢走；
    /// 已经选中的那张不必再等（minimumDuration 0），直接拖。
    private var bodyDrag: some Gesture {
        LongPressGesture(minimumDuration: selected ? 0 : 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 这里只代表手指刚按下，0.5 秒还没走完；快速点击也会经过这里。
                    // 真正通过长按门槛以后，SequenceGesture 才会进入 .second。
                    break
                case .second(true, let d):
                    if !lifted {
                        if !selected { onSelect() }
                        lifted = true
                        onBusyChange?(true)
                        liftTick += 1
                    }
                    if let d { drag = d.translation }
                default:
                    break
                }
            }
            .onEnded { value in
                defer { onBusyChange?(false) }
                guard case .second(true, let d) = value, let d else {
                    lifted = false; drag = .zero; return
                }
                onMove(CGPoint(x: item.x + d.translation.width,
                               y: item.y + d.translation.height))
                lifted = false
                drag = .zero
                liftTick += 1
            }
    }

    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                onBusyChange?(true)
                let anchor = grabbed ?? Xform(scale: item.scale, rotation: item.rotation)
                var rot = live?.rotation ?? anchor.rotation
                if grabbed == nil {
                    grabbed = anchor
                    rot = anchor.rotation
                    liftTick += 1
                }
                let v0 = handleVector(anchor)
                let len0 = hypot(v0.x, v0.y)
                guard len0 > 1 else { return }
                let vx = v0.x + v.translation.width
                let vy = v0.y + v.translation.height

                // 缩放 = 手指到中心的距离与起手时的比值；
                // 转多少 = 每帧的角度增量攒起来，绕过 ±180° 也不会突然翻面
                let now = atan2(Double(vy), Double(vx)) * 180 / .pi
                var d = now - (lastFingerAngle
                               ?? atan2(Double(v0.y), Double(v0.x)) * 180 / .pi)
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                lastFingerAngle = now

                let raw = anchor.scale * hypot(vx, vy) / len0
                live = Xform(scale: min(max(raw, PlacedMetrics.minScale), PlacedMetrics.maxScale),
                             rotation: rot + d)
            }
            .onEnded { _ in
                if let f = live { onTransform(f.scale, f.rotation) }
                grabbed = nil
                lastFingerAngle = nil
                live = nil
                tapTick += 1
                onBusyChange?(false)
            }
    }

    /// 手柄中心相对元素中心的屏幕向量。
    /// 角上那 13（半径）跟着元素一起转；手柄本身被反向转正了，
    /// 所以它自己那半径要在旋转之外再减回来，算出来才是手指真正按住的点。
    private func handleVector(_ x: Xform) -> CGPoint {
        let half = PlacedMetrics.handleSize / 2
        let cx = art.size.width / 2 * x.scale + half
        let cy = art.size.height / 2 * x.scale + half
        let r = x.rotation * .pi / 180
        let c = CGFloat(cos(r)), s = CGFloat(sin(r))
        return CGPoint(x: cx * c - cy * s - half,
                       y: cx * s + cy * c - half)
    }
}

// —— 容器 ————————————————————————————————
struct PlacedLayer: View {
    var day: Int
    var library: StickerLibrary
    var onBusyChange: ((Bool) -> Void)? = nil
    /// 摆贴纸模式，由贴纸栏的开合驱动
    var editable: Bool = true
    /// 时间轴内容高度，传 DayView 的 timelineH（1042）
    var contentHeight: CGFloat
    @Binding var selectedID: UUID?

    @Environment(CalendarStore.self) private var store

    /// 画布宽，全工程写死 402
    private let canvasW: CGFloat = 402

    var body: some View {
        // 自带一层 topLeading 的 ZStack：offset 的基准点必须是时间轴内容的左上角，
        // 交给外面那层 ZStack 去摊平的话，对齐方式就不在自己手里了
        ZStack(alignment: .topLeading) {
            ForEach(store.placed(on: day)) { item in
                let art = PlacedArt.resolve(item, library: library)
                PlacedItemView(
                    item: item,
                    art: art,
                    selected: selectedID == item.id,
                    onSelect: { selectedID = item.id },
                    onMove: { p in
                        store.updatePlaced(id: item.id, on: day, x: p.x, y: p.y)
                    },
                    onTransform: { s, r in
                        store.updatePlaced(id: item.id, on: day, scale: s, rotation: r)
                    },
                    onTear: {
                        if selectedID == item.id { selectedID = nil }
                        store.removePlaced(id: item.id, on: day)
                    },
                    onBusyChange: onBusyChange,
                    editable: editable
                )
                // 存的是中心点，换成 topLeading 基准
                .offset(x: item.x - art.size.width / 2,
                        y: item.y - art.size.height / 2)
                // 选中的那张压在同层其他张上面
                .zIndex(selectedID == item.id ? 1 : 0)
            }
        }
    }

}

// —— 月视图角上的缩略 ————————————————————————
// 位置选右上角。88pt 格子里已经占掉的地方：日期数字在左上（只占最左约 14pt）、
// 事件文字从 y17 往下铺、生理期条横贯 y2–20、今天/纪念日印章居中偏下、
// 分类贴纸占左下、空相框和 NEW!! 占右下 —— 右上是全格唯一常年空着的整块，
// 而且跟右下的 NEW!! 分居对角线两端，两个小东西不会挤成一坨。
// 生理期那六天会压住一点点胶带条，但那本来就是平铺的浅粉底，日期数字也是直接压上去的，
// 同一套拼贴逻辑，不算打架。
struct PlacedThumbs: View {
    var items: [PlacedItem]
    var library: StickerLibrary

    /// 最多露三张，露最近贴的；数组尾巴那张画在最上面
    private var shown: [PlacedItem] {
        Array(items.sorted { $0.placedAt > $1.placedAt }.prefix(3).reversed())
    }

    /// 跟月视图那几张分类贴纸一个量级（行李箱 38×35、咖啡杯 38×22），
    /// 不再是角落里那个 16pt 的小点
    private let side: CGFloat = 34

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                // 越晚贴的越靠上靠右，一张压着一张，像随手摞的一叠
                thumb(item)
                    .rotationEffect(.degrees(Double(i) * 6 - 5))
                    .offset(x: CGFloat(i) * 7, y: CGFloat(-i) * 5)
            }
        }
        .padding(.leading, 2)
        .padding(.bottom, 2)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func thumb(_ item: PlacedItem) -> some View {
        switch item.kind {
        case .photo:
            // 16pt 下相框 PNG 的模切纹路会糊成一团，改用同比例的白边小卡片顶替
            //（92:143 来自 InstaxEmptyFrame 日视图定稿）
            Group {
                if let f = item.photoFile, let img = PhotoVault.thumbnail(f, maxPixel: 48) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Paper.instaxFill
                }
            }
            .frame(width: side / PlacedMetrics.instaxAspect, height: side)
            .clipped()
            .padding(1.2)
            .background(Color.white)
            .shadow(color: Paper.cardShadow, radius: 0.8, x: 0.5, y: 0.8)
        case .sticker:
            if let img = PlacedArt.stickerImage(item, library: library) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: side, height: side)
            }
        case .emoji:
            // 月视图这一格才 16pt，emoji 直接用字画就够清楚，不必走位图
            Text(item.emoji ?? "")
                .font(.system(size: side * 0.92))
                .frame(width: side, height: side)
        }
    }
}
