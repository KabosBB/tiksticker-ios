import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied into our temp folder.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Movie(url: dst)
        }
    }
}

struct VideoItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var pickerItem: PhotosPickerItem?
    @State private var video: VideoItem?
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    steps

                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("اختار فيديو تسجيل الشاشة", systemImage: "video.badge.plus")
                    }
                    .buttonStyle(BigButtonStyle())

                    if loading {
                        HStack { ProgressView(); Text("بفتح الفيديو…") }
                    }

                    HStack {
                        Text("الباكات بتاعتك").font(.title3.bold())
                        Spacer()
                        Button("＋ باك جديد") { store.startNewPack() }
                    }
                    .padding(.top, 8)

                    if store.visiblePacks.isEmpty {
                        Text("لسه مفيش استيكرات. سجّل الشاشة على الاستيكر في تيك توك واختار الفيديو.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.visiblePacks) { pack in
                        PackCard(pack: pack)
                    }

                    Text("• اضغط مطوّل على أي استيكر عشان تمسحه.\n• الباك فيه لحد ٣٠ استيكر، بعدها بيتعمل باك جديد لوحده.\n• لو ضفت استيكرات لباك موجود في واتساب، دوس «حدّث في واتساب».")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("استيكرات تيك توك")
        }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            load(item)
        }
        .fullScreenCover(item: $video) { v in
            EditorView(videoURL: v.url)
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .alert("مشكلة", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("الخطوات").font(.headline)
            Text("١. افتح تيك توك وروح للكومنت اللي فيه الاستيكر.")
            Text("٢. افتح مركز التحكم ودوس على زرار تسجيل الشاشة ⏺، سجّل ٣ ثواني والاستيكر ظاهر، ووقّف التسجيل.")
            Text("٣. ارجع هنا ودوس «اختار فيديو تسجيل الشاشة».")
            Text("٤. حط المربع على الاستيكر ودوس «اعمل الاستيكر»، وبعدين «ضيفه لواتساب».")
            Text("لو مش لاقي زرار التسجيل: الإعدادات ← مركز التحكم ← ضيف «تسجيل الشاشة».")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func load(_ item: PhotosPickerItem) {
        loading = true
        Task {
            do {
                if let movie = try await item.loadTransferable(type: Movie.self) {
                    video = VideoItem(url: movie.url)
                } else {
                    errorText = "مقدرتش أفتح الفيديو ده"
                }
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
            pickerItem = nil
        }
    }
}

struct PackCard: View {
    @EnvironmentObject var store: Store
    let pack: Pack
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(pack.name)  (\(pack.stickers.count)/\(Store.maxStickers))" + (pack.sent ? "  ✓ في واتساب" : ""))
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pack.stickers, id: \.self) { f in
                        WebPView(url: store.url(pack.id, f))
                            .frame(width: 72, height: 72)
                            .padding(4)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.delete(packId: pack.id, file: f)
                                } label: {
                                    Label("امسحه", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            if pack.stickers.count < Store.minStickers {
                Text("واتساب محتاج ٣ استيكرات في الباك، لو ضفته دلوقتي هكرر الموجود لحد ما تجمع ٣.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(pack.sent ? "🔄 حدّث في واتساب" : "➕ ضيف الباك لواتساب") {
                do {
                    try WhatsApp.send(pack: pack, store: store)
                    store.markSent(pack.id)
                } catch {
                    errorText = error.localizedDescription
                }
            }
            .buttonStyle(BigButtonStyle())
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .alert("مشكلة", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }
}
