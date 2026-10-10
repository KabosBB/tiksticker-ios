import SwiftUI
import UIKit
import ImageIO

/// Shows an (animated) WebP file. iOS 14+ ImageIO reads WebP natively.
struct WebPView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        v.image = AnimatedLoader.load(url)
    }
}

enum AnimatedLoader {
    private static let cache = NSCache<NSURL, UIImage>()

    static func load(_ url: URL) -> UIImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        var images: [UIImage] = []
        var total = 0.0
        for i in 0..<n {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
                if let d = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, d > 0 {
                    delay = d
                } else if let d = webp[kCGImagePropertyWebPDelayTime] as? Double, d > 0 {
                    delay = d
                }
            }
            total += delay
        }
        let img: UIImage? = images.count > 1 ? UIImage.animatedImage(with: images, duration: total) : images.first
        if let img = img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}
