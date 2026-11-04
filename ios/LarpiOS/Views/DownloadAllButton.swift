import SwiftUI

/// Кнопка «Скачать весь плейлист локально» с прогрессом и отменой.
struct DownloadAllButton: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let tracks: [Track]

    var body: some View {
        if downloads.bulkActive, let bulk = downloads.bulk {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("\(bulk.done + bulk.failed)/\(bulk.total)")
                    .font(.caption)
                    .monospacedDigit()
                Button {
                    downloads.cancelBulk()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Отменить скачивание")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .adaptiveGlass(cornerRadius: 18)
        } else {
            Button {
                downloads.downloadAll(tracks)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .accessibilityLabel("Скачать все")
            .padding(6)
            .adaptiveGlass(cornerRadius: 18)
        }
    }
}
