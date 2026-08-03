import SwiftUI

// ============================================================
// StickerLibrary.swift — 贴纸抽屉里有什么。
//
// 两种来源：
//   · 内置：Assets 里那几张，Mac 上预先烤好了白边
//   · 自己加的：导入时烤一次，PNG 落在 Documents/Stickers/，之后每次用都是现成图
// 索引存 index.json，跟 PNG 放一起，删一张就连文件一起删。
// ============================================================

@Observable final class StickerLibrary {

    struct Item: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        /// Assets 里的名字（内置）
        var builtIn: String? = nil
        /// Documents/Stickers 下的文件名（自己加的）
        var file: String? = nil
        var addedAt: Date = Date()

        var isBuiltIn: Bool { builtIn != nil }
    }

    /// 内置那几张。拍立得相框、胶带、印章、红笔标记都不算普通贴纸，不进抽屉。
    ///
    /// id 必须是钉死的常量。之前写成 `builtInNames.map { Item(builtIn: $0) }`，
    /// 而 Item.id 默认值是 UUID()，于是每读一次 all 就重新发一批 id——
    /// 贴到日历上的内置贴纸下一帧就认不回来（渲染成空框），
    /// prunePlacedStickers 还会把它们当孤儿全删掉。自己导入的不受影响，那些 id 是落盘的。
    static let builtInItems: [Item] = [
        Item(id: UUID(uuidString: "5713CA70-0000-4000-A000-000000000001")!, builtIn: "halftone-cat-sleeping"),
        Item(id: UUID(uuidString: "5713CA70-0000-4000-A000-000000000002")!, builtIn: "halftone-camera"),
        Item(id: UUID(uuidString: "5713CA70-0000-4000-A000-000000000003")!, builtIn: "halftone-coffee-cup"),
        Item(id: UUID(uuidString: "5713CA70-0000-4000-A000-000000000004")!, builtIn: "admit-one-ticket"),
        Item(id: UUID(uuidString: "5713CA70-0000-4000-A000-000000000005")!, builtIn: "red-heart-outline"),
    ]
    static var builtInNames: [String] { builtInItems.compactMap(\.builtIn) }

    private(set) var mine: [Item] = []
    /// 抽屉里的顺序：自己加的在前（新的最前），内置的垫后面
    var all: [Item] {
        mine.sorted { $0.addedAt > $1.addedAt } + Self.builtInItems
    }

    init() { load() }

    // —— 取图 ————————————————————————————————
    func image(for item: Item) -> UIImage? {
        if let name = item.builtIn { return UIImage(named: name) }
        guard let file = item.file else { return nil }
        if let cached = cache[file] { return cached }
        guard let img = UIImage(contentsOfFile: Self.dir.appendingPathComponent(file).path)
        else { return nil }
        cache[file] = img
        return img
    }

    // —— 加一张 ——————————————————————————————
    /// 烤好再落盘。这一步只在导入时跑一次。
    @discardableResult
    func add(from photo: UIImage) async -> Item? {
        guard let baked = try? await StickerBaker.bake(photo),
              let data = baked.pngData() else { return nil }
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: Self.dir,
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.dir.appendingPathComponent(name), options: .atomic)
        } catch { return nil }
        let item = Item(file: name)
        mine.append(item)
        cache[name] = baked
        save()
        return item
    }

    func remove(_ item: Item) {
        guard let file = item.file else { return }        // 内置的删不掉
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(file))
        cache[file] = nil
        mine.removeAll { $0.id == item.id }
        save()
    }

    // —— 落盘 ————————————————————————————————
    private var cache: [String: UIImage] = [:]

    private static let dir: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stickers", isDirectory: true)
    }()
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        // 索引里有、文件没了的条目直接丢掉，免得抽屉里出现空白格
        mine = list.filter {
            guard let f = $0.file else { return false }
            return FileManager.default.fileExists(
                atPath: Self.dir.appendingPathComponent(f).path)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mine) else { return }
        try? FileManager.default.createDirectory(at: Self.dir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}
