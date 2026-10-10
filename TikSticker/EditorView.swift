import SwiftUI
import AVFoundation

struct ResultItem: Identifiable {
    let id = UUID()
    let packId: String
    let file: String
}

/// Shows a frame of the recording with a box the user puts over the sticker.
struct EditorView: View {
    let videoURL: URL
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var asset: AVURLAsset
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var length: Double = 3
    @State private var frame: UIImage?
    @State private var videoSize: CGSize = .zero
    @State private var box: CGRect = .zero // 0...1, relative to the video frame
    @State private var working = false
    @State private var result: ResultItem?
    @State private var errorText: String?
    @State private var frameTask: Task<Void, Never>?
    @AppStorage("removeBg") private var removeBg = true
    @AppStorage("lastBox") private var lastBox = ""

    init(videoURL: URL) {
        self.videoURL = videoURL
        _asset = State(initialValue: AVURLAsset(url: videoURL))
    }

    private var lengths: [Double] {
        let all: [Double] = [2, 3, 5]
        let ok = all.filter { $0 <= duration - start + 0.05 }
        return ok.isEmpty ? [max(0.2, (duration - start).rounded(.down))] : ok
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(10)
                }
                Spacer()
                Text("حدد الاستيكر").font(.headline)
                Spacer()
                Color.clear.frame(width: 40, height: 1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)

            GeometryReader { geo in
                let area = Self.fit(videoSize, in: geo.size)
                ZStack {
                    if let frame = frame {
                        Image(uiImage: frame)
                            .resizable()
                            .frame(width: area.width, height: area.height)
                            .position(x: area.midX, y: area.midY)
                    }
                    if area.width > 0 && box.width > 0 {
                        SelectionOverlay(box: $box, area: area, full: geo.size)
                    }
                    if frame == nil { ProgressView().tint(.white) }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .environment(\.layoutDirection, .leftToRight)

            controls
        }
        .background(Color.black.ignoresSafeArea())
        .task { await setup() }
        .onChange(of: start) { t in
            frameTask?.cancel()
            frameTask = Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { return }
                await loadFrame(at: t)
            }
            if !lengths.contains(length), let l = lengths.last { length = l }
        }
        .sheet(item: $result) { r in
            ResultSheet(item: r, again: { result = nil }, finish: {
                result = nil
                dismiss()
            })
            .environmentObject(store)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .alert("مشكلة", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("حرّك المربع من النص، وكبّره أو صغّره من الأركان")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
            if duration > 0.3 {
                HStack {
                    Text("البداية").foregroundColor(.white)
                    Slider(value: $start, in: 0...max(0.01, duration - 0.2))
                }
            }
            HStack {
                Text("المدة").foregroundColor(.white)
                Picker("المدة", selection: $length) {
                    ForEach(lengths, id: \.self) { l in
                        Text(l == l.rounded() ? "\(Int(l)) ث" : String(format: "%.1f ث", l)).tag(l)
                    }
                }
                .pickerStyle(.segmented)
            }
            Toggle("شيل الخلفية", isOn: $removeBg)
                .foregroundColor(.white)
            Button {
                make()
            } label: {
                if working {
                    HStack { ProgressView().tint(.white); Text("بجهّز الاستيكر…") }
                } else {
                    Text("✂️ اعمل الاستيكر")
                }
            }
            .buttonStyle(BigButtonStyle())
            .disabled(working || frame == nil)
        }
        .padding()
        .background(Color(white: 0.11))
    }

    // MARK: - logic

    static func fit(_ img: CGSize, in area: CGSize) -> CGRect {
        guard img.width > 0, img.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let s = min(area.width / img.width, area.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    private func setup() async {
        if let d = try? await asset.load(.duration) {
            duration = max(0.1, d.seconds.isFinite ? d.seconds : 0.1)
        }
        length = lengths.contains(3) ? 3 : (lengths.last ?? 1)
        await loadFrame(at: 0)
        if box == .zero { box = restoredBox() }
    }

    private func restoredBox() -> CGRect {
        let parts = lastBox.split(separator: ",").compactMap { Double($0) }
        if parts.count == 4, parts[2] > 0.02, parts[3] > 0.02 {
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        let w = 0.45
        let h = videoSize.height > 0 ? min(0.9, w * videoSize.width / videoSize.height) : 0.2
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func loadFrame(at t: Double) async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
            frame = UIImage(cgImage: cg)
            videoSize = CGSize(width: cg.width, height: cg.height)
        } else if frame == nil {
            errorText = "مقدرتش أقرا الفيديو"
        }
    }

    private func make() {
        guard videoSize.width > 0, box.width > 0 else { return }
        working = true
        lastBox = "\(box.minX),\(box.minY),\(box.width),\(box.height)"
        let crop = CGRect(x: box.minX * videoSize.width, y: box.minY * videoSize.height,
                          width: box.width * videoSize.width, height: box.height * videoSize.height)
        let asset = self.asset
        let s = start
        let l = max(0.2, min(length, duration - start))
        let rb = removeBg
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { () -> StickerResult in
                    let ex = try await Processor.extract(asset: asset, crop: crop, start: s, duration: l)
                    return try Processor.run(frames: ex.frames, w: ex.w, h: ex.h, removeBg: rb)
                }.value
                let saved = try store.add(webp: r.webp, tray: r.tray)
                result = ResultItem(packId: saved.packId, file: saved.file)
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}

/// Dimmed screen with a movable / resizable box. `box` is relative (0...1) to `area`.
struct SelectionOverlay: View {
    @Binding var box: CGRect
    let area: CGRect
    let full: CGSize
    @State private var startBox: CGRect?

    private var rect: CGRect {
        CGRect(x: area.minX + box.minX * area.width, y: area.minY + box.minY * area.height,
               width: box.width * area.width, height: box.height * area.height)
    }

    var body: some View {
        ZStack {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: full))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(Color.white, lineWidth: 2.5))
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)
                .gesture(drag(move: true) { s, dx, dy in s.offsetBy(dx: dx, dy: dy) })

            handle(CGPoint(x: rect.minX, y: rect.minY)) { s, dx, dy in
                CGRect(x: s.minX + dx, y: s.minY + dy, width: s.width - dx, height: s.height - dy)
            }
            handle(CGPoint(x: rect.maxX, y: rect.minY)) { s, dx, dy in
                CGRect(x: s.minX, y: s.minY + dy, width: s.width + dx, height: s.height - dy)
            }
            handle(CGPoint(x: rect.minX, y: rect.maxY)) { s, dx, dy in
                CGRect(x: s.minX + dx, y: s.minY, width: s.width - dx, height: s.height + dy)
            }
            handle(CGPoint(x: rect.maxX, y: rect.maxY)) { s, dx, dy in
                CGRect(x: s.minX, y: s.minY, width: s.width + dx, height: s.height + dy)
            }
        }
        .frame(width: full.width, height: full.height)
    }

    private func handle(_ p: CGPoint, _ f: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some View {
        Circle()
            .fill(accent)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 24, height: 24)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .position(p)
            .gesture(drag(move: false, f))
    }

    private func drag(move: Bool, _ f: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if startBox == nil { startBox = box }
                let s = startBox ?? box
                let dx = v.translation.width / max(area.width, 1)
                let dy = v.translation.height / max(area.height, 1)
                var r = f(s, dx, dy)
                if move {
                    r.origin.x = min(max(0, r.origin.x), 1 - r.width)
                    r.origin.y = min(max(0, r.origin.y), 1 - r.height)
                } else {
                    r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    if r.isNull || r.width < 0.05 || r.height < 0.03 { return }
                }
                box = r
            }
            .onEnded { _ in startBox = nil }
    }
}

struct ResultSheet: View {
    @EnvironmentObject var store: Store
    let item: ResultItem
    let again: () -> Void
    let finish: () -> Void
    @State private var errorText: String?

    var body: some View {
        let pack = store.pack(item.packId)
        let count = pack?.stickers.count ?? 1
        ScrollView {
            VStack(spacing: 14) {
                WebPView(url: store.url(item.packId, item.file))
                    .frame(width: 200, height: 200)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 24)
                Text("اتعمل الاستيكر ✓").font(.title3.bold())
                Text("اتحفظ في «\(pack?.name ?? "")» (\(count) استيكر)")
                    .foregroundColor(.secondary)
                if count < Store.minStickers {
                    Text("واتساب محتاج ٣ في الباك، لو ضفته دلوقتي هكرر الموجود لحد ما تجمع ٣.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("➕ ضيفه لواتساب") {
                    guard let p = store.pack(item.packId) else { return }
                    do {
                        try WhatsApp.send(pack: p, store: store)
                        store.markSent(p.id)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .buttonStyle(BigButtonStyle())
                HStack(spacing: 10) {
                    Button("🔁 خد تاني") { again() }
                        .buttonStyle(BigButtonStyle(filled: false))
                    Button("🗑 امسحه") {
                        store.delete(packId: item.packId, file: item.file)
                        again()
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                }
                Button("خلاص") { finish() }
                    .buttonStyle(BigButtonStyle(filled: false))
            }
            .padding()
        }
        .alert("مشكلة", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }
}
