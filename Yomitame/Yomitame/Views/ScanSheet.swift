import SwiftUI
import SwiftData
import AVFoundation

/// 連続スキャン画面。カメラを開いたまま何冊でも読み、下に積み上げてから一括で本棚へ入れる。
/// 1冊ごとに閉じさせない（棚を作るときは10冊まとめて登録したい）。
struct ScanSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var scanned: [BookCandidate] = []
    @State private var misses: [String] = []          // 読めたが書誌が引けなかったISBN
    @State private var permission: Permission = .unknown

    private let service = BookSearchService()

    enum Permission { case unknown, granted, denied }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    camera
                    results
                }
            }
            .navigationTitle("バーコードをスキャン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { addAll() }
                        .tint(.white)
                        .disabled(scanned.isEmpty)
                }
            }
            .task { await requestCamera() }
        }
    }

    @ViewBuilder
    private var camera: some View {
        ZStack {
            switch permission {
            case .granted:
                BarcodeScannerView { code in
                    Task { await resolve(code) }
                }
            case .denied:
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.title).foregroundStyle(Theme.sub)
                    Text("カメラを使えません")
                        .foregroundStyle(.white)
                    Text("設定 → よみため → カメラ をオンにしてください。")
                        .font(.caption).foregroundStyle(Theme.sub)
                }
            case .unknown:
                ProgressView().tint(.white)
            }

            if permission == .granted {
                VStack {
                    Spacer()
                    Label("本の裏のバーコードをかざしてください", systemImage: "barcode.viewfinder")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(height: 280)
        .clipped()
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("スキャンした本")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !scanned.isEmpty {
                    Text("\(scanned.count)冊")
                        .font(.caption).foregroundStyle(Theme.gold)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.vertical, 12)

            if scanned.isEmpty && misses.isEmpty {
                Spacer()
                Text("スキャンした本がここに表示されます")
                    .font(.callout)
                    .foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(scanned) { c in
                        HStack(spacing: 12) {
                            CoverImage(url: c.coverURL, title: c.title).frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.subheadline).lineLimit(2).foregroundStyle(.white)
                                Text(c.authors).font(.caption).lineLimit(1).foregroundStyle(Theme.sub)
                            }
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(Theme.gold)
                        }
                        .listRowBackground(Theme.bg)
                    }
                    ForEach(misses, id: \.self) { isbn in
                        HStack {
                            Image(systemName: "questionmark.circle").foregroundStyle(Theme.sub)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("書誌が見つかりません").font(.subheadline).foregroundStyle(Theme.sub)
                                Text(isbn).font(.caption2).foregroundStyle(Theme.sub.opacity(0.7))
                            }
                        }
                        .listRowBackground(Theme.bg)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Button("\(scanned.count)冊を本棚に入れる") { addAll() }
                .buttonStyle(PrimaryButton())
                .disabled(scanned.isEmpty)
                .opacity(scanned.isEmpty ? 0.4 : 1)
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 8)
        }
    }

    // MARK: -

    private func requestCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            permission = .denied
        }
    }

    private func resolve(_ isbn: String) async {
        guard !scanned.contains(where: { $0.isbn13 == isbn }) else { return }
        if let hit = await service.lookup(isbn: isbn) {
            scanned.insert(hit, at: 0)
        } else if !misses.contains(isbn) {
            misses.insert(isbn, at: 0)
        }
    }

    private func addAll() {
        for c in scanned { context.insert(Book(from: c)) }
        dismiss()
    }
}
