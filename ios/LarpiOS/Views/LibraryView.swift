import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            groupView
        }
    }

    private var groupView: some View {
        Group {
            if library.liked.isEmpty && library.localFiles.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .navigationTitle("Библиотека")
        .safeAreaInset(edge: .bottom) {
            if library.pendingSyncCount > 0 {
                pendingBanner
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Добавить трек")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            library.addLocalFile(from: url, fileName: url.lastPathComponent)
        }
        .onAppear {
            library.reloadLiked(autoDownload: settings.autoDownloadLibrary)
            library.loadLocalFiles()
        }
    }

    /// Плашка: изменения, сделанные оффлайн, ждут отправки на компьютер.
    private var pendingBanner: some View {
        Button {
            Task { await library.syncLiked() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Изменения ждут синка с компьютером: \(library.pendingSyncCount)")
                    .font(.footnote)
                Spacer()
                Text("Повторить")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.18))
            .foregroundColor(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private var emptyView: ContentUnavailableViewCompat {
        ContentUnavailableViewCompat(
            systemImage: "heart",
            title: "Пока пусто",
            message: "Лайкай треки в поиске или добавь файл плюсом"
        )
    }

    private var listView: some View {
        List {
            localFilesSection
            if !library.liked.isEmpty {
                likedSection
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var localFilesSection: some View {
        if !library.localFiles.isEmpty {
            Section("Локальные файлы") {
                ForEach(Array(library.localFiles.enumerated()), id: \.element.searchKey) { idx, track in
                    Button {
                        player.play(library.localFiles, startAt: idx)
                    } label: {
                        TrackRowView(track: track,
                                     isPlaying: player.currentTrack?.searchKey == track.searchKey)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            library.removeLocalFile(track)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var likedSection: some View {
        Section("Любимое") {
            ForEach(Array(library.liked.enumerated()), id: \.element.searchKey) { idx, track in
                Button {
                    player.play(library.liked, startAt: idx)
                } label: {
                    TrackRowView(track: track,
                                 isPlaying: player.currentTrack?.searchKey == track.searchKey)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        library.toggleLike(track, autoDownload: true)
                    } label: {
                        Label("Убрать", systemImage: "heart.slash")
                    }
                }
            }
        }
    }
}

/// Небольшой адаптер ContentUnavailableView для iOS 15 (он появился в iOS 17).
struct ContentUnavailableViewCompat: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title).font(.title3).bold()
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}