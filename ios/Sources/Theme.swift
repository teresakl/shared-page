import SwiftUI

// ============================================================
// Theme.swift — 所有颜色 / 字体 / 素材名 的唯一出处。
// ⚠️ CC 施工规则：不要改这里的任何数值；页面代码只允许引用这些常量。
// 设计稿画布 402×874pt（iPhone 16 Pro 点值），HTML px == SwiftUI pt，1:1 照搬。
// ============================================================

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Ink {
    // 作者笔迹色（月/日视图事件文字、图例、便签作者标签）
    static let kitty  = Color(hex: 0xD4737F)
    static let master = Color(hex: 0x629BA7)                      // AI 侧：青（原蓝灰 7E97C4 → 薄荷 62A793 → 最后定在 H=190，S/B 不动）
    static let system = Color(hex: 0x9A9490)
    // 便签正文手写色（比笔迹色深，可读性）
    static let noteKitty  = Color(hex: 0xC9556A)
    static let noteMaster = Color(hex: 0x274E56)                  // 深青（原深蓝 2F4C79 → 深薄荷 27564A → H 190）
    // 版面
    static let title    = Color(hex: 0x5C4249)                    // July / 日期标题 / 星期字母
    static let titleDim = Color(hex: 0x86646A, alpha: 0.52)       // "2026"
    static let sub      = Color(hex: 0x86646A, alpha: 0.62)       // Caveat 副标题
    static let subLight = Color(hex: 0x86646A, alpha: 0.55)
    static let hourLbl  = Color(hex: 0x86646A, alpha: 0.50)
    static let dimDay   = Color(hex: 0x86646A, alpha: 0.34)       // 非本月日期数字
    static let today    = Color(hex: 0xD4737F)                    // 今天数字
    static let legend   = Color(hex: 0x86646A, alpha: 0.78)
}

enum Paper {
    static let card       = Color.white
    static let border     = Color(hex: 0xE4C2C6)                  // 卡片外框 1.4pt / 分隔线 1.3pt
    static let gridLine   = Color(hex: 0xE6C4C8, alpha: 0.95)     // 单元格分隔 0.8pt / 小时线 1pt
    static let texture    = Color(hex: 0xD6AAB0, alpha: 0.20)     // 13pt 方格纸纹理线
    static let cardShadow = Color(hex: 0xD6A0A6, alpha: 0.22)     // offset(3,3) blur 0
    static let period     = Color(hex: 0xFBDDE4)                  // 生理期胶带条
    static let block      = Color(hex: 0xD67884, alpha: 0.11)     // 跨天安排色带：KITTY
    static let blockAssistant = Color(hex: 0x4F99A8, alpha: 0.13)     // 跨天安排色带：AI 侧（H 190）
    static let blockAuto  = Color(hex: 0x9A9490, alpha: 0.13)     // 跨天安排色带：AUTO
    static let blockPick  = Color(hex: 0xD67884, alpha: 0.20)     // 正在拖选时的预览带，比落定的深一档
    static let eventBg    = Color(hex: 0xD67884, alpha: 0.08)     // KITTY 的事件块底：浅粉
    static let eventBgAssistant = Color(hex: 0x4F99A8, alpha: 0.11)   // AI 侧的事件块底：浅青（H 190）
    static let eventBgAuto  = Color(hex: 0x9A9490, alpha: 0.13)   // AUTO 的事件块底：浅灰
    static let instaxFill = Color(hex: 0xEFEAE3)                  // 空相框窗口底色
    static let fab        = Color(hex: 0xF4D9DE)                  // 右下 + 按钮
    static let capsule    = Color(hex: 0xFBEEF1)                  // 时间/日期胶囊底，比 fab 再淡一档
    static let navBorder  = Color(hex: 0xDEB4BA)                  // ◀ ▶ 边框
}

// 字体：TTF 在 Resources/Fonts，登记于 project.yml 的 UIAppFonts（必须写纯文件名，
// 资源会被拍平到 bundle 根，带目录前缀会静默注册失败）。
//
// 两个人两种笔迹（开源版：手写体统一指到霞鹜文楷，
// 想换笔迹把下面 hand()/handUIFont() 里的字体名换成自己的 ttf 就行）：
//   用户侧 = 霞鹜文楷，字距 -2.0
//   AI 侧 = 霞鹜文楷，字距默认
//   系统/AUTO 与所有 UI 中文 = 霞鹜文楷
// 霞鹜文楷原档 23MB，已裁到 GB2312 全字库（7544 字）3.4MB；用户输入常用汉字都在里面。
enum Fonts {
    static func serif(_ s: CGFloat) -> Font { .custom("InstrumentSerif-Regular", size: s) }        // July（纯西文）
    static func mono(_ s: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: s)                             // 数字/标签
    }
    static func script(_ s: CGFloat) -> Font { .custom("Caveat-Medium", size: s) }                  // 英文副标题

    /// UI 中文：日期标题、图例、空状态、以后的按钮
    static func body(_ s: CGFloat) -> Font { .custom("LXGWWenKai-Regular", size: s) }

    /// 手写体，按作者给不同笔迹。
    /// 文楷的字面（字形占 em 的比例）比两款手写体大，同样 pt 数看着撑一号，
    /// 所以系统这一路统一乘 0.86 再用，视觉大小才跟两边手写体的字对齐。
    /// 日视图 0.6；月视图格子基准字号本来就小，再乘 0.6 会掉到 7pt 出头，单开 0.7
    static let systemScale: CGFloat = 0.6
    static let systemScaleMonth: CGFloat = 0.7
    static func hand(_ s: CGFloat, _ a: Author = .kitty, month: Bool = false) -> Font {
        switch a {
        case .kitty:  return .custom("LXGWWenKai-Regular", size: s)
        case .master: return .custom("LXGWWenKai-Regular", size: s)
        case .system: return .custom("LXGWWenKai-Regular",
                                     size: s * (month ? systemScaleMonth : systemScale))
        }
    }

    /// 配套字距。small 用于月视图 12pt 格子——原值照搬会粘成一坨，收一半。
    /// 三种笔迹统一用文楷,字距统一 0(文楷自带的间距就是设计好的)。
    /// 换成自己的手写体后要是嫌松,在这儿给对应笔迹一个负值收紧,
    /// 分段下发的机制(中文收、英文数字不收)还在,直接就能用
    static func kern(_ a: Author, small: Bool = false) -> CGFloat {
        let base: CGFloat = 0
        return small ? base * 0.5 : base
    }

    /// 中文字符(含全宽标点)才吃手写体的负字距——拉丁字母和数字本来就窄,
    /// 再收就挤成一坨看不清()
    static func isCJK(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(u) || (0xF900...0xFAFF).contains(u)
            || (0xFF00...0xFFEF).contains(u)
    }

    /// 用户侧手写体的分段字距:中文照旧收紧,英文数字一律不收。
    /// 连续同类字符归成一段逐段下发 kern,同一句话里中英各用各的间距
    static func kittyKerned(_ s: String, small: Bool = false) -> AttributedString {
        let k = kern(.kitty, small: small)
        var out = AttributedString()
        var i = s.startIndex
        while i < s.endIndex {
            let cjk = isCJK(s[i])
            var j = i
            while j < s.endIndex, isCJK(s[j]) == cjk { j = s.index(after: j) }
            var piece = AttributedString(String(s[i..<j]))
            piece.kern = cjk ? k : 0
            out += piece
            i = j
        }
        return out
    }

    /// 手写文本的统一出口(显示端用):用户侧走分段字距,AI 侧/系统平铺(kern 本来就是 0)。
    /// 输入框(TextField/TextEditor)吃不了分段,编辑态保持旧的统一字距
    static func handText(_ s: String, _ a: Author, small: Bool = false) -> Text {
        a == .kitty ? Text(kittyKerned(s, small: small)) : Text(s)
    }

    /// 排版测量用。SwiftUI 的 Font 量不了行数，得拿 UIFont 走 CoreText。
    static func handUIFont(_ s: CGFloat, _ a: Author) -> UIFont {
        let name: String
        switch a {
        case .kitty:  name = "LXGWWenKai-Regular"
        case .master: name = "LXGWWenKai-Regular"
        case .system: name = "LXGWWenKai-Regular"
        }
        let size = (a == .system) ? s * systemScale : s
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }
}

// 便签纸就那么宽，能写几个字得按真实排版算，不能按字数拍脑袋。
enum NoteFit {
    static let maxLines = 2
    /// 便签宽 174 － 左右内边距各 15
    static let textWidth: CGFloat = 144

    static func lineCount(_ text: String, author: Author) -> Int {
        if text.isEmpty { return 1 }
        // 测量必须跟显示端同一套分段字距,不然两行截断会算错(8/2 分段化时同步)
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: Fonts.handUIFont(16, author),
            .kern: Fonts.kern(author)
        ])
        if author == .kitty {
            var i = text.startIndex
            while i < text.endIndex {
                let cjk = Fonts.isCJK(text[i])
                var j = i
                while j < text.endIndex, Fonts.isCJK(text[j]) == cjk { j = text.index(after: j) }
                attr.addAttribute(.kern, value: cjk ? Fonts.kern(.kitty) : 0,
                                  range: NSRange(i..<j, in: text))
                i = j
            }
        }
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(x: 0, y: 0,
                                       width: textWidth,
                                       height: .greatestFiniteMagnitude), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as? [CTLine])?.count ?? 1
    }

    static func fits(_ text: String, author: Author) -> Bool {
        if text.components(separatedBy: .newlines).count > maxLines { return false }
        return lineCount(text, author: author) <= maxLines
    }

    /// 塞不下就从尾巴上削，削到刚好两行为止；削掉的不留
    static func truncate(_ text: String, author: Author) -> String {
        var s = String(text.prefix(CalNote.maxChars))
        while !s.isEmpty && !fits(s, author: author) { s.removeLast() }
        return s
    }
}

// 素材 → 语义 固定映射（一类一素材；Asset Catalog 内的图名 = 文件名去扩展名）
enum Sticker: String {
    case photoFrame   = "instax-mini-frame"      // 照片/空相框（窗口透明，内衬 instaxFill）
    case catSticker   = "halftone-cat-sleeping"  // 通用贴纸 & "贴贴纸"按钮
    case travel       = "halftone-camera"        // 旅行（行李箱）
    case movie        = "admit-one-ticket"       // 电影/演出（仅日视图）
    case food         = "halftone-coffee-cup"    // 吃饭/咖啡
    case notePaper    = "grid-scrap-strip"       // 留言便签撕边格纸
    case tape         = "gingham-tape-short"     // 胶带（AI 侧=薄荷绿滤镜版）
    case newBadge     = "red-exclaim-double"     // 新内容 !!
    case likeHeart    = "red-heart-outline"      // 点赞红心
    case checkMark    = "red-check-mark"         // 已完成（日视图）
    case strike       = "red-strikethrough"      // 已完成划掉（月视图）
    case dateCircle   = "pink-date-circle"       // 选中日期粉圈
    case todayStamp   = "stamp-date-circle"      // 今天 · 日期印章
    case annivStamp   = "stamp-heart-mini"       // 纪念日 · 爱心印章
    var image: Image { Image(rawValue) }
}
