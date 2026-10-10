import Foundation

/// Builds an animated WebP out of single-frame WebP files (what WebPEncodeRGBA produces).
enum WebpMux {
    static func imageChunks(_ webp: Data, alpha: inout Bool) -> Data {
        let b = [UInt8](webp)
        var out = Data()
        guard b.count >= 20,
              b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
              b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 else { return out }
        var pos = 12
        while pos + 8 <= b.count {
            let fourcc = String(bytes: b[pos..<(pos + 4)], encoding: .ascii) ?? ""
            let size = Int(b[pos + 4]) | Int(b[pos + 5]) << 8 | Int(b[pos + 6]) << 16 | Int(b[pos + 7]) << 24
            let padded = size + (size & 1)
            let total = min(8 + padded, b.count - pos)
            if fourcc == "ALPH" || fourcc == "VP8 " || fourcc == "VP8L" {
                out.append(contentsOf: b[pos..<(pos + total)])
                if total < 8 + padded { out.append(0) }
                if fourcc != "VP8 " { alpha = true }
            }
            pos += 8 + padded
        }
        return out
    }

    static func build(frames: [Data], durations: [Int], width: Int, height: Int) -> Data {
        var alpha = false
        var anmfs = Data()
        for (i, f) in frames.enumerated() {
            let data = imageChunks(f, alpha: &alpha)
            var p = Data()
            u24(&p, 0)
            u24(&p, 0)
            u24(&p, width - 1)
            u24(&p, height - 1)
            u24(&p, max(20, durations[i]))
            p.append(0x02) // do not blend, no disposal
            p.append(data)
            chunk(&anmfs, "ANMF", p)
        }
        var body = Data()
        var vp8x = Data()
        vp8x.append(0x02 | (alpha ? 0x10 : 0))
        vp8x.append(contentsOf: [0, 0, 0])
        u24(&vp8x, width - 1)
        u24(&vp8x, height - 1)
        chunk(&body, "VP8X", vp8x)
        chunk(&body, "ANIM", Data([0, 0, 0, 0, 0, 0])) // transparent background, loop forever
        body.append(anmfs)

        var file = Data()
        file.append(contentsOf: Array("RIFF".utf8))
        u32(&file, body.count + 4)
        file.append(contentsOf: Array("WEBP".utf8))
        file.append(body)
        return file
    }

    /// Same picture, slightly different bytes (changes the unused ANIM background colour).
    /// WhatsApp needs 3 stickers per pack, so we repeat the ones we have.
    static func variant(_ d: Data, tag: UInt8) -> Data {
        var b = [UInt8](d)
        let anim: [UInt8] = Array("ANIM".utf8)
        var i = 12
        while i + 12 <= b.count {
            if Array(b[i..<(i + 4)]) == anim {
                b[i + 8] = tag
                break
            }
            i += 1
        }
        return Data(b)
    }

    private static func chunk(_ o: inout Data, _ fourcc: String, _ payload: Data) {
        o.append(contentsOf: Array(fourcc.utf8))
        u32(&o, payload.count)
        o.append(payload)
        if payload.count % 2 == 1 { o.append(0) }
    }

    private static func u24(_ o: inout Data, _ v: Int) {
        o.append(UInt8(v & 0xff))
        o.append(UInt8((v >> 8) & 0xff))
        o.append(UInt8((v >> 16) & 0xff))
    }

    private static func u32(_ o: inout Data, _ v: Int) {
        u24(&o, v)
        o.append(UInt8((v >> 24) & 0xff))
    }
}
