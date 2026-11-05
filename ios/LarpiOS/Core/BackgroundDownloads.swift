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
    var onFileSystemFailure: ((BackgroundTransferMetadata, String) -> Void)?
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
        guard let response = downloadTask.response as? HTTPURLResponse else {
            onFailure?(metadata, "Демон вернул ответ без HTTP статуса")
            return
        }
        let status = response.statusCode
        guard status == 200 || status == 206 else {
            onFailure?(metadata, responseError(at: location, status: status))
            return
        }

        do {
            let fileManager = FileManager.default
            let temporaryAttributes = try fileManager.attributesOfItem(atPath: location.path)
            let temporarySize = (temporaryAttributes[.size] as? NSNumber)?.int64Value ?? 0
            guard temporarySize >= 1_024 else {
                onFailure?(metadata, "Демон передал пустой или слишком маленький аудиофайл")
                return
            }
            let downloads = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            let destination = downloads.appendingPathComponent("\(metadata.key).mp3")
            // URLSession's temporary download may live on a different volume.
            // Copy to a staging file in Documents, then rename atomically.
            let staging = downloads.appendingPathComponent(".\(metadata.key)-\(UUID().uuidString).download")
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: location, to: staging)
            let stagedAttributes = try fileManager.attributesOfItem(atPath: staging.path)
            let stagedSize = (stagedAttributes[.size] as? NSNumber)?.int64Value ?? 0
            guard stagedSize == temporarySize else {
                onFailure?(metadata, "Аудиофайл скопировался не полностью")
                return
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            onFinished?(metadata, destination)
        } catch {
            let nsError = error as NSError
            onFileSystemFailure?(metadata, "Не удалось сохранить \(metadata.track.title): \(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let metadata = BackgroundTransferMetadata.decode(task.taskDescription) else { return }
        let nsError = error as NSError
        let filesystemErrorCodes = [
            URLError.Code.cannotCreateFile.rawValue,
            URLError.Code.cannotWriteToFile.rawValue,
            URLError.Code.cannotCloseFile.rawValue
        ]
        if nsError.domain == NSURLErrorDomain && filesystemErrorCodes.contains(nsError.code) {
            onFileSystemFailure?(metadata, error.localizedDescription)
        } else {
            onFailure?(metadata, "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]")
        }
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
