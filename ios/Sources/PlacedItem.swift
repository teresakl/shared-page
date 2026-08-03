import SwiftUI
import ImageIO

// ============================================================
// PlacedItem.swift — 贴在时间轴上的东西（贴纸 / 照片）的数据层。
//
// 存储放在单独的 PlacedStore.shared，不放 CalendarStore 里：
//   CalendarStore 是 @Observable class，extension 里加不了存储属性；
//   而 CalendarStore.swift 是定稿文件，这一版不动它。
//   SwiftUI 的观察按「body 里读了哪个 @Observable 的哪个属性」注册，
//   跟对象是从 environment 拿的还是从单例拿的无关，走单例照样刷新。
//   以后想改成 CalendarStore 持有：在那边加一行 let placedStore = PlacedStore()，
//   把本文件转发层里的 PlacedStore.shared 全换成 self.placedStore 即可，视图层不动。
//
// 落盘：位置数据 Documents/placed.json，照片原件 Documents/Photos/*.jpg。
// placed.json 的顶层键是 "2026-07-17" 这种日键。老版本只有 2026 年 7 月一个月，
// 写下的是裸日号（"17"），读的时候会被认成那个月，然后整份重写一次；
// 重写之前先把原件复制成 placed-legacy.json，写完读回来点一遍条数，
// 对不上就把原件放回去。读盘只要失败过，这一趟就一个字节都不往回写 ——
// 盘上那份是唯一的原件，盖掉就没了。
// 接网关 REST 时的两个口子：replaceAll 灌全量、didMutate 推改动。
// ============================================================

struct PlacedItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    enum Kind: String, Codable { case sticker, photo, emoji }
    var kind: Kind
    /// sticker 时指向 StickerLibrary.Item.id
    var stickerID: UUID? = nil
    /// photo 时是 Documents/Photos 下的文件名
    var photoFile: String? = nil
    /// emoji 时就存那个字符本身，不落盘也不进抽屉
    var emoji: String? = nil
    /// 时间轴坐标系里的中心点。x 在 0...402 画布内，y 在 0...timelineH 内容坐标
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat = 1
    var rotation: Double = 0
    var placedAt: Date = Date()
}

extension PlacedItem {
    /// 设计画布宽（Theme.swift 头部：402×874）
    static let canvasWidth: CGFloat = 402
    /// 日视图时间轴内容高。10 + 18*52 + 96，跟 DayView.timelineH 是同一个式子
    static let canvasHeight: CGFloat = 1042
    /// 捏合上下限：再小就缩成一个点捡不回来，再大能盖住整屏
    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 3.0
    /// 中心点离画布边至少留这么多，免得贴纸一半在屏外、手指够不着
    static let edgeInset: CGFloat = 8

    static func clamp(x: CGFloat) -> CGFloat { min(max(edgeInset, x), canvasWidth - edgeInset) }
    static func clamp(y: CGFloat) -> CGFloat { min(max(edgeInset, y), canvasHeight - edgeInset) }
    static func clamp(scale: CGFloat) -> CGFloat { min(max(minScale, scale), maxScale) }
}

// ============================================================
// 照片原件：Documents/Photos
// 贴纸走 StickerLibrary（要抠图、要烤白边），照片是原样塞进拍立得框，
// 两条路的处理完全不同，所以分开存，互不打扰。
// ============================================================
enum PhotoVault {
    /// 长边上限。iPhone 原图 4032px 一张好几 MB，
    /// 而它最大只显示在日视图 92pt 宽的拍立得窗口里，1600 已经远远够
    static let maxPixel: CGFloat = 1600
    /// 相册照片没有透明通道，JPEG 比 PNG 小一个数量级
    static let quality: CGFloat = 0.86

    static let dir: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos", isDirectory: true)
    }()

    static func url(for file: String) -> URL { dir.appendingPathComponent(file) }

    static func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: file).path)
    }

    /// 压完再落盘，返回文件名。写不进去返回 nil，调用方就别建这条 PlacedItem
    static func save(_ image: UIImage) -> String? {
        guard let data = downscaled(image).jpegData(compressionQuality: quality) else { return nil }
        let name = "\(UUID().uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url(for: name), options: .atomic)
        } catch { return nil }
        return name
    }

    static func delete(_ file: String) {
        try? FileManager.default.removeItem(at: url(for: file))
        // 缓存不用跟着清：文件名是 UUID，删掉后不会有同名新文件来命中这条旧缓存
    }

    // —— 取图 ————————————————————————————————
    static func image(_ file: String) -> UIImage? {
        let key = file as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(contentsOfFile: url(for: file).path) else { return nil }
        cache.setObject(img, forKey: key, cost: cost(img))
        return img
    }

    /// 月视图格子里的拍立得窗口只有 34×53pt（MonthView 定稿值），
    /// 为它解一整张 1600px 的位图太亏 —— 走 ImageIO 直接解小图，不经过全尺寸
    static func thumbnail(_ file: String, maxPixel: CGFloat = 220) -> UIImage? {
        let key = "\(file)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url(for: file) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // 带上 EXIF 旋转，不然缩略图是躺着的
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
        return img
    }

    // 一张 1600px 的图解开是 7MB 上下，一个月的照片全留着会撑爆内存；
    // NSCache 按字节记账，到顶了系统自己淘汰
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    private static func cost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    /// 按像素算缩放比，不直接看 UIImage.size —— 那是点值，还得乘 scale 才是真像素。
    /// draw(in:) 顺手把 EXIF 旋转摆正（跟 StickerBaker.normalized 同一个道理）
    private static func downscaled(_ image: UIImage) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale,
                        height: image.size.height * image.scale)
        guard px.width > 0, px.height > 0 else { return image }
        let ratio = min(1, maxPixel / max(px.width, px.height))
        let target = CGSize(width: (px.width * ratio).rounded(),
                            height: (px.height * ratio).rounded())
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1        // 按 1pt=1px 画，否则 Retina 上会再放大三倍，白压
        f.opaque = true
        return UIGraphicsImageRenderer(size: target, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// ============================================================
// PlacedStore — 哪一天贴了什么，贴在哪儿
// ============================================================
@Observable final class PlacedStore {
    /// 全局一份；CalendarStore 那边只做转发，不持有
    static let shared = PlacedStore()

    /// 老版本只有 2026 年 7 月这一个月，盘上的纯数字键全是那个月的。
    /// 这个常量钉死不动 —— 换成「当前年月」的话，用户贴在 7/15、7/17 的东西会整批跑到 8 月去
    private static let legacyMonth = CalMonth.sample

    /// 文件在、但读不出来。这种时候宁可什么都不显示，也绝对不能往上写
    @ObservationIgnored private var loadFailed = false

    /// 哪一天贴了什么。键就是磁盘上那个 "2026-07-17"，内存和盘上是同一套写法
    private(set) var byKey: [String: [PlacedItem]] = [:]

    /// 改完一天之后回调，参数是被改的那天的日键。以后接网关，上行推送挂这里
    @ObservationIgnored var didMutate: ((String) -> Void)?

    private init() { load() }

    // —— 查 ————————————————————————————————
    func items(key: String) -> [PlacedItem] { byKey[key] ?? [] }

    /// 月视图格子角落只放得下两三个，按贴上去的先后倒着取
    func recent(key: String, limit: Int) -> [PlacedItem] {
        Array(items(key: key).sorted { $0.placedAt > $1.placedAt }.prefix(max(0, limit)))
    }

    // —— 改 ————————————————————————————————
    func place(_ item: PlacedItem, key: String) {
        var it = item
        it.x = PlacedItem.clamp(x: it.x)
        it.y = PlacedItem.clamp(y: it.y)
        it.scale = PlacedItem.clamp(scale: it.scale)
        byKey[key, default: []].append(it)
        persist(key, immediate: true)
    }

    /// 只传要改的那几项：拖动给 x/y，捏合给 scale/rotation
    func update(id: UUID, key: String,
                x: CGFloat? = nil, y: CGFloat? = nil,
                scale: CGFloat? = nil, rotation: Double? = nil) {
        guard let i = byKey[key]?.firstIndex(where: { $0.id == id }) else { return }
        if let x { byKey[key]![i].x = PlacedItem.clamp(x: x) }
        if let y { byKey[key]![i].y = PlacedItem.clamp(y: y) }
        if let scale { byKey[key]![i].scale = PlacedItem.clamp(scale: scale) }
        if let rotation { byKey[key]![i].rotation = rotation }
        persist(key, immediate: false)
    }

    /// 撕掉。photo 连底下的文件一起删，删之前先确认没有别处还在用
    func remove(id: UUID, key: String) {
        guard let i = byKey[key]?.firstIndex(where: { $0.id == id }) else { return }
        let gone = byKey[key]!.remove(at: i)
        if byKey[key]?.isEmpty == true { byKey[key] = nil }
        if let file = gone.photoFile, !isPhotoStillUsed(file) { PhotoVault.delete(file) }
        persist(key, immediate: true)
    }

    /// 眼下每次导入都写新文件，一张照片只会被一条 PlacedItem 引用；
    /// 这道检查是为了以后做「复制一份贴到别天」时不会误删掉还在用的图
    private func isPhotoStillUsed(_ file: String) -> Bool {
        byKey.values.contains { $0.contains { $0.photoFile == file } }
    }

    /// 整份换掉，留给以后从网关拉全量
    func replaceAll(_ map: [String: [PlacedItem]]) {
        byKey = map
        persist(nil, immediate: true)
    }

    /// 贴纸从抽屉里删掉后，已经贴出去的那些会变成空白，顺手清一遍。
    /// 传 StickerLibrary.all 里还活着的那批 id，返回清掉几个
    @discardableResult
    func pruneStickers(keeping ids: Set<UUID>) -> Int {
        var dropped = 0
        for (k, list) in byKey {
            let kept = list.filter { $0.kind != .sticker || ($0.stickerID.map(ids.contains) ?? false) }
            guard kept.count != list.count else { continue }
            dropped += list.count - kept.count
            byKey[k] = kept.isEmpty ? nil : kept
            didMutate?(k)      // 这天的纸面少了东西，页面渲染那边要知道
        }
        if dropped > 0 { persist(nil, immediate: true) }
        return dropped
    }

    /// 退到后台前手动落一次，把还在攒着的那次写掉
    func flush() {
        saveToken += 1
        writeToDisk()
    }

    // —— 落盘 ————————————————————————————————
    private static let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("placed.json")
    }()

    // 盘上一律存成 {"2026-07-17": [...]} 这种规规矩矩的 JSON 对象。
    // 键是补过零的日键，字典序正好就是时间序，打开文件一眼看得出哪天贴了什么；
    // 日期同理走 ISO8601，别用 Swift 默认的参考日期浮点数。
    // 老版本写下的裸日号键（"17" 这种）也读得进来，会被认成 2026 年 7 月
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        // 文件还不存在 = 合法的空白起点，照常允许写盘
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.fileURL) else { loadFailed = true; return }
        guard let raw = try? Self.decoder().decode([String: [PlacedItem]].self, from: data) else {
            loadFailed = true      // 格式变了/写坏了，这一趟一个字节都不许往回写
            return
        }
        var map: [String: [PlacedItem]] = [:]
        var sawLegacy = false
        for (key, list) in raw {
            let k: String
            if let n = Int(key) {
                k = Self.legacyMonth.dayKey(n)   // 老格式 "15" → "2026-07-15"
                sawLegacy = true
            } else {
                k = key                          // 认不出来的键原样留着，绝不丢
            }
            // 图没了的条目直接丢掉，免得时间轴上留一块永远加载不出来的空白
            // （跟 StickerLibrary.load 对缺文件的处理一致）
            let alive = list.filter {
                $0.kind != .photo || ($0.photoFile.map(PhotoVault.exists) ?? false)
            }
            if !alive.isEmpty { map[k, default: []].append(contentsOf: alive) }
        }
        byKey = map
        if sawLegacy { migrateOnce() }
    }

    /// 见到老键才跑一次：先把原件留一份，再按新格式整份重写，写完读回来点个数
    private func migrateOnce() {
        let backup = Self.fileURL.deletingLastPathComponent()
            .appendingPathComponent("placed-legacy.json")
        // 只在备份还不存在时建。已经有备份 = 迁过一次了，
        // 绝不能拿这次的结果去盖掉那份好的
        if !FileManager.default.fileExists(atPath: backup.path) {
            do { try FileManager.default.copyItem(at: Self.fileURL, to: backup) }
            catch { return }   // 备份没成就先不重写，老文件一个字节没动，下次启动再来
        }
        writeToDisk()
        // 写完立刻读回来对一遍条数，对得上就算过
        if let d = try? Data(contentsOf: Self.fileURL),
           let back = try? Self.decoder().decode([String: [PlacedItem]].self, from: d),
           back.values.reduce(0, { $0 + $1.count }) == byKey.values.reduce(0, { $0 + $1.count }) {
            return
        }
        // 对不上：把备份原样放回去，并且这一趟以后都不许再写
        try? FileManager.default.removeItem(at: Self.fileURL)
        try? FileManager.default.copyItem(at: backup, to: Self.fileURL)
        loadFailed = true
    }

    private func writeToDisk() {
        // 读盘失败过就一律不写。磁盘上那份是唯一的原件，盖掉就没了
        guard !loadFailed else { return }
        var raw: [String: [PlacedItem]] = [:]
        for (k, list) in byKey where !list.isEmpty { raw[k] = list }
        guard let data = try? Self.encoder().encode(raw) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    @ObservationIgnored private var saveToken = 0

    /// 贴上去/撕下来是一次性动作，直接写盘；
    /// 拖动和捏合可能连着调很多次，攒 0.35s 只写一次
    private func persist(_ key: String?, immediate: Bool) {
        if let key { didMutate?(key) }
        saveToken += 1                      // 之前排队的那次作废
        if immediate { writeToDisk(); return }
        let token = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.saveToken == token else { return }
            self.writeToDisk()
        }
    }
}

// ============================================================
// 转发层 —— 视图那边只跟 store 打交道，不用知道 PlacedStore 存在。
// 形状照着 CalendarStore 现有的 events / events(on:) 来。
// ============================================================
extension CalendarStore {

    /// 整份读写。网关拉全量时用得上；日常增删走下面那几个方法
    var placed: [String: [PlacedItem]] {
        get { PlacedStore.shared.byKey }
        set { PlacedStore.shared.replaceAll(newValue) }
    }

    func placed(on day: Int) -> [PlacedItem] { PlacedStore.shared.items(key: month.dayKey(day)) }

    /// 月视图格子角落用，按贴上去的时间倒着取前几个
    func recentPlaced(on day: Int, limit: Int = 3) -> [PlacedItem] {
        PlacedStore.shared.recent(key: month.dayKey(day), limit: limit)
    }

    func hasPlaced(on day: Int) -> Bool { !PlacedStore.shared.items(key: month.dayKey(day)).isEmpty }

    func place(_ item: PlacedItem, on day: Int) { PlacedStore.shared.place(item, key: month.dayKey(day)) }

    func updatePlaced(id: UUID, on day: Int,
                      x: CGFloat? = nil, y: CGFloat? = nil,
                      scale: CGFloat? = nil, rotation: Double? = nil) {
        PlacedStore.shared.update(id: id, key: month.dayKey(day), x: x, y: y, scale: scale, rotation: rotation)
    }

    func removePlaced(id: UUID, on day: Int) { PlacedStore.shared.remove(id: id, key: month.dayKey(day)) }

    func flushPlaced() { PlacedStore.shared.flush() }

    func prunePlacedStickers(keeping ids: Set<UUID>) {
        PlacedStore.shared.pruneStickers(keeping: ids)
    }

    // —— 照片 ————————————————————————————————
    /// 压到长边 1600 再落盘，返回 Documents/Photos 下的文件名
    func importPhoto(_ image: UIImage) -> String? { PhotoVault.save(image) }

    func photoURL(for file: String) -> URL { PhotoVault.url(for: file) }
    func photoImage(for file: String) -> UIImage? { PhotoVault.image(file) }

    /// 月视图那种小格子用这个，别拿全尺寸图去填 34pt 的窗口
    func photoThumbnail(for file: String, maxPixel: CGFloat = 220) -> UIImage? {
        PhotoVault.thumbnail(file, maxPixel: maxPixel)
    }

    /// 一条 PlacedItem 该画哪张图：贴纸去抽屉里认 id，照片去 Photos 里拿文件。
    /// 抽屉规模就几十张，直接线性找 —— 建索引反而要跟 StickerLibrary 的增删同步状态
    func image(for item: PlacedItem, library: StickerLibrary) -> UIImage? {
        switch item.kind {
        case .photo:
            guard let file = item.photoFile else { return nil }
            return PhotoVault.image(file)
        case .sticker:
            guard let sid = item.stickerID,
                  let hit = library.all.first(where: { $0.id == sid }) else { return nil }
            return library.image(for: hit)
        case .emoji:
            // emoji 不落盘，每次按字符现渲染（EmojiRenderer 自带缓存）
            return item.emoji.flatMap { EmojiRenderer.image($0) }
        }
    }
}
