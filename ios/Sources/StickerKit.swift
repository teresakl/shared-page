import SwiftUI

// ============================================================
// StickerKit.swift — 所有拼贴素材的封装视图。
// ⚠️ 每个素材的尺寸/旋转/偏移都是设计定稿值，写死在这里；
//    页面层只负责"放在哪一天"，不允许再调整这些数值。
// ============================================================

// —— 空拍立得相框（照片占位，等用户上传）——————————————
// 窗口透明区：left/right 10.7%，top 9.6%，bottom 22%（相对框尺寸）
struct InstaxEmptyFrame: View {
    var width: CGFloat            // 月视图 34 / 日视图 92
    var height: CGFloat           // 月视图 53 / 日视图 143
    var rotation: Double          // 月视图 -4 / 日视图 -3.5
    var body: some View {
        ZStack(alignment: .topLeading) {
            Paper.instaxFill
                .frame(width: width * 0.786, height: height * 0.684)
                .offset(x: width * 0.107, y: height * 0.096)
            Sticker.photoFrame.image.resizable()
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .rotationEffect(.degrees(rotation))
        .shadow(color: Color(hex: 0x966E73, alpha: 0.4), radius: 1.5, x: 1, y: 1.5)
        .allowsHitTesting(false)
    }
}

// —— 格纹胶带（用户侧原色 / AI 侧薄荷绿 = 同一素材加滤镜）—————
struct GinghamTape: View {
    var width: CGFloat
    var height: CGFloat
    var rotation: Double
    /// AI 侧 = true。胶带素材底色量出来是 H=7.4，所以转 183° 正好落在 190 —— 跟 Ink.master 同一档青色。
    /// （历史：206° 蓝 → 168° 薄荷绿 → 183° 青）
    var mint: Bool = false
    var body: some View {
        Sticker.tape.image.resizable()
            .frame(width: width, height: height)
            .hueRotation(.degrees(mint ? 183 : 0))
            .saturation(mint ? 0.78 : 1)
            .brightness(mint ? 0.04 : 0)
            .rotationEffect(.degrees(rotation))
            .allowsHitTesting(false)
    }
}

// —— 印章（今天 / 纪念日）：multiply 叠底 —————————————
struct StampView: View {
    var sticker: Sticker
    var size: CGFloat
    var rotation: Double
    var opacity: Double
    var body: some View {
        sticker.image.resizable()
            .frame(width: size, height: size)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }
}

// —— NEW 双感叹号（15×15.5，wobble 4°↔10° 3.4s）———————
struct NewBadge: View {
    @State private var wob = false
    var body: some View {
        Sticker.newBadge.image.resizable()
            .frame(width: 15, height: 15.5)
            .rotationEffect(.degrees(wob ? 10 : 4))
            .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: wob)
            .onAppear { wob = true }
            .allowsHitTesting(false)
    }
}

// —— 月视图已完成划掉：盖在事件文字上，宽 96%，高 8，透明度 .55 —
// 红笔划掉线。按定稿去掉，月视图那两处调用已经拿掉，
// 素材和画法先留在这儿——真要回来的时候不用重画
struct StrikeOverlay: View {
    var body: some View {
        Sticker.strike.image.resizable()
            .frame(height: 8)
            .opacity(0.55)
            .allowsHitTesting(false)
    }
}

// —— 撕边格纸便签（日视图留言）————————————————————
// 宽固定 174；纸=grid-scrap-strip 拉伸铺满；内边距 14/15/15；
// 便签整体旋转：第0/2/4…张 -2.2°，第1/3…张 +1.6°；
// 胶带：用户侧 52×25 顶部居中 +6°；AI 侧同尺寸贴左上角(-14,-11) -19° 蓝色。
struct TornNoteView: View {
    var note: CalNote
    var index: Int
    /// 压在哪条日程上，就把那条的名字写在纸角
    var linkedTitle: String? = nil
    /// 正被手指拎着：抬起来一点、影子拉长
    var lifted: Bool = false
    /// 正在纸上写字：内嵌输入框、自动聚焦
    var editing: Bool = false
    var onTextChange: ((String) -> Void)? = nil

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(note.author.rawValue) · \(note.timestamp)")
                    .font(Fonts.mono(7)).kerning(0.4)
                    .foregroundColor(note.author == .master ? Ink.master : Ink.kitty)
                if editing {
                    // 直接在纸上写，不再另开窗口；写满两行就打不进去
                    TextEditor(text: $draft)
                        .font(Fonts.hand(16, note.author)).kerning(Fonts.kern(note.author))
                        .foregroundColor(note.author == .master ? Ink.noteMaster : Ink.noteKitty)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($focused)
                        .frame(height: 46)          // 正好两行的高度
                        .padding(.leading, -5)      // TextEditor 自带内缩，抵掉
                        .onAppear { draft = note.text; focused = true }
                        .onChange(of: draft) { _, v in
                            // 超过两行的部分当场削掉，不留
                            let cut = NoteFit.truncate(v, author: note.author)
                            if cut != v { draft = cut }
                            onTextChange?(cut)
                        }
                } else {
                    Fonts.handText(note.text, note.author)
                        .font(Fonts.hand(16, note.author))
                        .foregroundColor(note.author == .master ? Ink.noteMaster : Ink.noteKitty)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let linkedTitle {
                    Text("↳ \(linkedTitle)")
                        .font(Fonts.mono(6.5)).kerning(0.3)
                        .foregroundColor(note.author == .master ? Ink.master : Ink.kitty)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 15, bottom: 26, trailing: 15))
            .frame(width: 174, alignment: .topLeading)
            .background(
                Sticker.notePaper.image.resizable()   // 100%/100% 拉伸，与设计稿一致
            )
        }
        .overlay(alignment: note.author == .master ? .topLeading : .top) {
            GinghamTape(width: 52, height: 25,
                        rotation: note.author == .master ? -19 : 6,
                        mint: note.author == .master)
                .offset(x: note.author == .master ? -14 : 0, y: -11)
        }
        .overlay(alignment: .bottomTrailing) {
            // 双击 AI 侧的便签点赞：心从纸的右下角弹出来，再点一下缩回去。
            // 位置尺寸旋转全是定稿数值，这里只管它怎么冒出来
            Sticker.likeHeart.image.resizable()
                .frame(width: 26, height: 25)
                .rotationEffect(.degrees(9))
                .scaleEffect(note.liked ? 1 : 0.15, anchor: .bottomTrailing)
                .opacity(note.liked ? 1 : 0)
                .offset(x: -8, y: 11)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.34, dampingFraction: 0.6), value: note.liked)
        }
        .rotationEffect(.degrees(lifted ? 0 : (index % 2 == 1 ? 1.6 : -2.2)))
        .scaleEffect(lifted ? 1.05 : 1)
        .shadow(color: Color(hex: 0x96787D, alpha: lifted ? 0.42 : 0.3),
                radius: lifted ? 8 : 2.5, x: lifted ? 3 : 1.5, y: lifted ? 7 : 2)
    }
}

// —— 分类贴纸的定稿尺寸 ——————————————————————————
// 月视图格子内（左下角）：travel 38×35 -5° (x2,y从底2)；food 38×22 -3° (x1,底2)
// 日视图时间轴上：travel 92×84 -5°；movie 118×49 -5°；food 104×60 -3°；
//                猫贴纸 92×98 -6°（右侧 18，top 340）
struct CategorySticker: View {
    var category: DayCategory
    var large: Bool               // true = 日视图
    var body: some View {
        let spec: (Sticker, CGFloat, CGFloat, Double) = {
            switch (category, large) {
            case (.travel, false): return (.travel, 38, 35, -5)
            case (.food,   false): return (.food,   38, 22, -3)
            case (.movie,  false): return (.movie,  44, 18, -6)   // 月视图当前不启用，保留定稿值
            case (.travel, true):  return (.travel, 92, 84, -5)
            case (.movie,  true):  return (.movie, 118, 49, -5)
            case (.food,   true):  return (.food,  104, 60, -3)
            }
        }()
        spec.0.image.resizable().scaledToFit()
            .frame(width: spec.1, height: spec.2)
            .rotationEffect(.degrees(spec.3))
            .allowsHitTesting(false)
    }
}

// —— 方格纸纹理（13pt 网格，线色 Paper.texture）———————————
struct GridPaperTexture: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width { path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += 13 }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += 13 }
            ctx.stroke(path, with: .color(Paper.texture), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}


