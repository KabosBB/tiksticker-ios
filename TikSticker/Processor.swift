import UIKit
import AVFoundation
import libwebp

struct StickerResult {
    let webp: Data
    let tray: Data
}

enum StickerError: LocalizedError {
    case noFrames, tooBig, encode

    var errorDescription: String? {
        switch self {
        case .noFrames: return "مقدرتش أقرا الفيديو، جرّب فيديو تاني"
        case .tooBig: return "الاستيكر حجمه كبير أوي، جرّب مربع أصغر أو مدة أقل"
        case .encode: return "حصلت مشكلة وأنا بحوّل الاستيكر"
        }
    }
}

/// One captured picture (RGBA, straight alpha) and how long it stays on screen.
struct Frame {
    var px: [UInt8]
    var ms: Int
}

enum Processor {
    static let size = 512
    static let maxBytes = 480 * 1024   // WhatsApp limit is 500 KB
    static let maxTotalMs = 9500       // WhatsApp limit is 10 s
    static let maxCrop: CGFloat = 640

    // MARK: - reading the video

    /// `crop` is in pixels of the (upright) video frame.
    static func extract(asset: AVAsset, crop: CGRect, start: Double, duration: Double,
                        fps: Double = 12) async throws -> (frames: [Frame], w: Int, h: Int) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let scale = min(1, maxCrop / max(crop.width, crop.height, 1))
        let w = max(1, Int((crop.width * scale).rounded()))
        let h = max(1, Int((crop.height * scale).rounded()))
        let step = 1.0 / fps
        let stepMs = Int((step * 1000).rounded())
        var frames: [Frame] = []
        var t = start
        while t < start + duration - 0.001 {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            t += step
            guard let cg = try? await gen.image(at: time).image else { continue }
            let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
            let r = crop.integral.intersection(bounds)
            guard !r.isEmpty, let cropped = cg.cropping(to: r) else { continue }
            let px = rgba(cropped, w, h)
            if let last = frames.last, diff(last.px, px) < 1.2 {
                frames[frames.count - 1].ms += stepMs // nothing moved
            } else {
                frames.append(Frame(px: px, ms: stepMs))
            }
        }
        if frames.isEmpty { throw StickerError.noFrames }
        return (frames, w, h)
    }

    static func rgba(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// Mean absolute colour difference on a sample of pixels.
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count) / 4
        let step = max(1, n / 4000)
        var sum = 0, cnt = 0, i = 0
        while i < n {
            let o = i * 4
            sum += abs(Int(a[o]) - Int(b[o])) + abs(Int(a[o + 1]) - Int(b[o + 1])) + abs(Int(a[o + 2]) - Int(b[o + 2]))
            cnt += 3
            i += step
        }
        return cnt == 0 ? 0 : Double(sum) / Double(cnt)
    }

    // MARK: - making the sticker

    static func run(frames input: [Frame], w: Int, h: Int, removeBg: Bool) throws -> StickerResult {
        var frames = input
        cutLoop(&frames)

        let alpha = removeBg ? removeBackground(frames, w, h) : nil
        var box = CGRect(x: 0, y: 0, width: w, height: h)
        if let a = alpha, let b = bounds(a, w, h) { box = b }
        let margin: CGFloat = alpha != nil ? 16 : 0
        let s = CGFloat(size)
        let scale = min((s - 2 * margin) / box.width, (s - 2 * margin) / box.height)
        let dw = (box.width * scale).rounded(), dh = (box.height * scale).rounded()
        let dst = CGRect(x: ((s - dw) / 2).rounded(), y: ((s - dh) / 2).rounded(), width: dw, height: dh)

        var outs: [[UInt8]] = []
        var durs: [Int] = []
        for (i, f) in frames.enumerated() {
            outs.append(render(f.px, alpha: alpha?[i], w: w, h: h, box: box, dst: dst))
            durs.append(f.ms)
        }
        frames.removeAll()
        if outs.count == 1 { // a still picture still has to be an animation
            outs.append(outs[0])
            durs = [500, 500]
        }
        guard let tray = trayPNG(outs[0]) else { throw StickerError.encode }

        let qualities: [Float] = [80, 65, 50, 38, 28]
        while true {
            for q in qualities {
                var enc: [Data] = []
                for o in outs {
                    guard let d = encode(o, q) else { throw StickerError.encode }
                    enc.append(d)
                }
                let file = WebpMux.build(frames: enc, durations: durs, width: size, height: size)
                if file.count <= maxBytes { return StickerResult(webp: file, tray: tray) }
            }
            if outs.count <= 2 { break }
            // still too big: keep every other frame
            var no: [[UInt8]] = [], nd: [Int] = []
            var i = 0
            while i < outs.count {
                no.append(outs[i])
                nd.append(durs[i] + (i + 1 < durs.count ? durs[i + 1] : 0))
                i += 2
            }
            outs = no
            durs = nd
        }
        throw StickerError.tooBig
    }

    /// Stickers loop; when the recording holds the loop more than once keep a single loop.
    static func cutLoop(_ f: inout [Frame]) {
        if f.count >= 6 {
            var elapsed = f[0].ms
            for j in 1..<f.count {
                if j >= 4 && elapsed >= 600 && diff(f[0].px, f[j].px) < 4.0 {
                    f.removeSubrange(j...)
                    break
                }
                elapsed += f[j].ms
            }
        }
        var total = 0
        for i in 0..<f.count {
            total += f[i].ms
            if total > maxTotalMs {
                f.removeSubrange(max(i, 1)...)
                break
            }
        }
    }

    private static func quant(_ px: [UInt8], _ i: Int) -> Int {
        let o = i * 4
        return Int(px[o] >> 3) << 10 | Int(px[o + 1] >> 3) << 5 | Int(px[o + 2] >> 3)
    }

    /// Comment stickers sit on a flat background. Find that colour on the edge of the first
    /// frame and flood-fill it away from the edges of every frame.
    static func removeBackground(_ f: [Frame], _ w: Int, _ h: Int) -> [[UInt8]]? {
        let first = f[0].px
        var border: [Int] = []
        for x in 0..<w { border.append(x); border.append((h - 1) * w + x) }
        for y in 0..<h { border.append(y * w); border.append(y * w + w - 1) }
        var hist: [Int: Int] = [:]
        for i in border { hist[quant(first, i), default: 0] += 1 }
        guard let best = hist.max(by: { $0.value < $1.value }),
              Double(best.value) >= Double(border.count) * 0.35 else { return nil }
        var rs = 0, gs = 0, bs = 0, cnt = 0
        for i in border where quant(first, i) == best.key {
            rs += Int(first[i * 4]); gs += Int(first[i * 4 + 1]); bs += Int(first[i * 4 + 2]); cnt += 1
        }
        let br = rs / cnt, bg = gs / cnt, bb = bs / cnt
        let t1 = 38, t2 = 85

        var out: [[UInt8]] = []
        var stack = [Int](repeating: 0, count: w * h)
        for fr in f {
            let px = fr.px
            var a = [UInt8](repeating: 255, count: w * h)
            var seen = [Bool](repeating: false, count: w * h)
            var sp = 0

            func dist(_ i: Int) -> Int {
                let o = i * 4
                return max(abs(Int(px[o]) - br), abs(Int(px[o + 1]) - bg), abs(Int(px[o + 2]) - bb))
            }
            func visit(_ i: Int) {
                if seen[i] { return }
                let d = dist(i)
                if d <= t1 {
                    seen[i] = true
                    a[i] = 0
                    stack[sp] = i
                    sp += 1
                } else if d <= t2 {
                    seen[i] = true
                    a[i] = min(a[i], UInt8((d - t1) * 255 / (t2 - t1))) // soft edge
                }
            }

            for i in border where !seen[i] && dist(i) <= t1 {
                seen[i] = true
                a[i] = 0
                stack[sp] = i
                sp += 1
            }
            while sp > 0 {
                sp -= 1
                let i = stack[sp]
                let x = i % w, y = i / w
                if x > 0 { visit(i - 1) }
                if x < w - 1 { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y < h - 1 { visit(i + w) }
            }
            out.append(a)
        }
        return out
    }

    static func bounds(_ alpha: [[UInt8]], _ w: Int, _ h: Int) -> CGRect? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for a in alpha {
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where a[row + x] > 24 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        if maxX < 0 { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Applies the mask, crops to `box` and draws into the 512x512 canvas. Returns straight-alpha RGBA.
    static func render(_ px: [UInt8], alpha: [UInt8]?, w: Int, h: Int, box: CGRect, dst: CGRect) -> [UInt8] {
        var src = px
        if let a = alpha {
            for i in 0..<(w * h) {
                let al = Int(a[i]), o = i * 4
                src[o] = UInt8(Int(src[o]) * al / 255)
                src[o + 1] = UInt8(Int(src[o + 1]) * al / 255)
                src[o + 2] = UInt8(Int(src[o + 2]) * al / 255)
                src[o + 3] = a[i]
            }
        }
        var out = [UInt8](repeating: 0, count: size * size * 4)
        guard let img = cgImage(src, w, h, premultiplied: true), let cropped = img.cropping(to: box) else { return out }
        out.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: dst.minX, y: CGFloat(size) - dst.maxY, width: dst.width, height: dst.height))
        }
        for i in 0..<(size * size) { // un-premultiply for the encoder
            let o = i * 4
            let al = Int(out[o + 3])
            if al > 0 && al < 255 {
                out[o] = UInt8(min(255, Int(out[o]) * 255 / al))
                out[o + 1] = UInt8(min(255, Int(out[o + 1]) * 255 / al))
                out[o + 2] = UInt8(min(255, Int(out[o + 2]) * 255 / al))
            }
        }
        return out
    }

    static func cgImage(_ px: [UInt8], _ w: Int, _ h: Int, premultiplied: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        let info: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func encode(_ px: [UInt8], _ q: Float) -> Data? {
        var output: UnsafeMutablePointer<UInt8>? = nil
        let n: Int = px.withUnsafeBufferPointer { buf in
            Int(WebPEncodeRGBA(buf.baseAddress, Int32(size), Int32(size), Int32(size * 4), q, &output))
        }
        guard n > 0, let o = output else { return nil }
        defer { WebPFree(o) }
        return Data(bytes: o, count: n)
    }

    static func trayPNG(_ px: [UInt8]) -> Data? {
        guard let cg = cgImage(px, size, size, premultiplied: false) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let r = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format)
        return r.pngData { _ in
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: 96, height: 96))
        }
    }
}
