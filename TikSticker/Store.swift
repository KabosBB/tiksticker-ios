import Foundation

struct Pack: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var stickers: [String]
    var sent: Bool
}

private struct StoreFile: Codable {
    var counter: Int
    var current: String?
    var packs: [Pack]
}

/// Keeps the packs in Documents/packs/<id>/ plus a small JSON index.
final class Store: ObservableObject {
    static let maxStickers = 30
    static let minStickers = 3

    @Published private(set) var packs: [Pack] = []
    private var counter = 0
    private var current: String?
    private let root: URL
    private let index: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("packs", isDirectory: true)
        index = docs.appendingPathComponent("store.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: index), let s = try? JSONDecoder().decode(StoreFile.self, from: d) {
            counter = s.counter
            current = s.current
            packs = s.packs
        }
    }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func url(_ id: String, _ file: String) -> URL { dir(id).appendingPathComponent(file) }
    func pack(_ id: String) -> Pack? { packs.first { $0.id == id } }
    var visiblePacks: [Pack] { packs.reversed().filter { !$0.stickers.isEmpty } }

    private func save() {
        let s = StoreFile(counter: counter, current: current, packs: packs)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: index, options: .atomic) }
    }

    private func newPack() -> Int {
        counter += 1
        let id = "tiktok_\(counter)_\(Int(Date().timeIntervalSince1970) % 100000)"
        packs.append(Pack(id: id, name: "استيكرات تيك توك \(counter)", stickers: [], sent: false))
        current = id
        try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        return packs.count - 1
    }

    private func currentIndex() -> Int {
        if let c = current, let i = packs.firstIndex(where: { $0.id == c }),
           packs[i].stickers.count < Store.maxStickers {
            return i
        }
        return newPack()
    }

    func startNewPack() {
        if let c = current, let p = pack(c), p.stickers.isEmpty { return }
        _ = newPack()
        save()
    }

    /// Saves a finished sticker into the current pack. Returns the pack id and file name.
    func add(webp: Data, tray: Data) throws -> (packId: String, file: String) {
        let i = currentIndex()
        let id = packs[i].id
        try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        let base = "s\(Int(Date().timeIntervalSince1970 * 1000))"
        try webp.write(to: url(id, base + ".webp"))
        try tray.write(to: url(id, base + "_t.png"))
        packs[i].stickers.append(base + ".webp")
        save()
        return (id, base + ".webp")
    }

    func delete(packId: String, file: String) {
        guard let i = packs.firstIndex(where: { $0.id == packId }) else { return }
        packs[i].stickers.removeAll { $0 == file }
        try? FileManager.default.removeItem(at: url(packId, file))
        try? FileManager.default.removeItem(at: url(packId, file.replacingOccurrences(of: ".webp", with: "_t.png")))
        if packs[i].stickers.isEmpty && !packs[i].sent {
            try? FileManager.default.removeItem(at: dir(packId))
            if current == packId { current = nil }
            packs.remove(at: i)
        }
        save()
    }

    func markSent(_ id: String) {
        guard let i = packs.firstIndex(where: { $0.id == id }), !packs[i].sent else { return }
        packs[i].sent = true
        save()
    }
}
