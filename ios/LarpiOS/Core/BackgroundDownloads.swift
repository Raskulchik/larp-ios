import Foundation

struct BackgroundTransferMetadata: Codable, Sendable {
    let key: String
    let track: Track
    let isBulk: Bool

    var taskDescription: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ taskDescription: String?) -> BackgroundTransferMetadata? {
        guard let taskDescription,
              let data = Data(base64Encoded: taskDescription) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct RestoredBackgroundTransfer: Sendable {
    let metadata: BackgroundTransferMetadata
    let progress: Double
    let isRunning: Bool
}

final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((BackgroundTransferMetadata, Double) -> Void)?
    var onFinished: ((BackgroundTransferMetadata, URL) -> Void)?
    var onFailure: ((BackgroundTransferMetadata, String) -> Void)?
    var onEventsFinished: (() -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let metadata = BackgroundTransferMetadata.decode(downloadTask.taskDescription),
              totalBytesExpectedToWrite > 0 else { return }
        let progress = min(100, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        onProgress?(metadata, progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let metadata = BackgroundTransferMetadata.decode(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            onFailure?(metadata, responseError(at: location, status: status))
            return
        }

        do {
            let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let destination = downloads.appendingPathComponent("\(metadata.key).mp3")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onFinished?(metadata, destination)
        } catch {
            onFailure?(metadata, error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let metadata = BackgroundTransferMetadata.decode(task.taskDescription) else { return }
        onFailure?(metadata, error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEventsFinished?()
    }

    private func responseError(at url: URL, status: Int) -> String {
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            return message
        }
        return "Сервер ответил HTTP \(status)"
    }
}
