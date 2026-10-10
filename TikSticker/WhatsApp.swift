import UIKit

/// Hands a pack to WhatsApp the way WhatsApp's own iOS sticker sample does:
/// JSON on the pasteboard + the whatsapp://stickerPack link.
enum WhatsApp {
    enum Failure: LocalizedError {
        case notInstalled, empty

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "واتساب مش متثبت على الموبايل"
            case .empty: return "الباك فاضي"
            }
        }
    }

    static var installed: Bool {
        guard let u = URL(string: "whatsapp://send") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    static func send(pack: Pack, store: Store) throws {
        guard installed else { throw Failure.notInstalled }
        var datas: [Data] = pack.stickers.compactMap { try? Data(contentsOf: store.url(pack.id, $0)) }
        guard !datas.isEmpty, let first = pack.stickers.first,
              let tray = try? Data(contentsOf: store.url(pack.id, first.replacingOccurrences(of: ".webp", with: "_t.png")))
        else { throw Failure.empty }

        // WhatsApp needs at least 3 stickers: repeat what we have
        let real = datas.count
        var n = 0
        while datas.count < Store.minStickers {
            datas.append(WebpMux.variant(datas[n % real], tag: UInt8(datas.count)))
            n += 1
        }

        let stickers: [[String: Any]] = datas.map { ["image_data": $0.base64EncodedString(), "emojis": ["😀"]] }
        let json: [String: Any] = [
            "identifier": pack.id,
            "name": pack.name,
            "publisher": "TikSticker",
            "tray_image": tray.base64EncodedString(),
            "animated_sticker_pack": true,
            "stickers": stickers,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        UIPasteboard.general.setItems(
            [["net.whatsapp.third-party.sticker-pack": data]],
            options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 60)])
        if let u = URL(string: "whatsapp://stickerPack") {
            UIApplication.shared.open(u)
        }
    }
}
