import Foundation

@MainActor
final class ModelLibrary: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var models: [LocalModel] = []
    @Published var isDownloading = false
    @Published var downloadProgress = 0.0
    @Published var errorMessage: String?

    static let smallURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
    static let smallBytes: Int64 = 487_601_967
    private var destination: URL { AppPaths.models.appendingPathComponent("ggml-small.bin") }
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        refresh()
    }

    func refresh() {
        try? AppPaths.prepare()
        let extraDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Слышь/tools/whisper-models", isDirectory: true)
        var seenNames = Set<String>()
        var found: [LocalModel] = []
        for folder in [AppPaths.models, extraDir] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls where url.pathExtension.lowercased() == "bin" {
                let filename = url.lastPathComponent.lowercased()
                guard seenNames.insert(filename).inserted else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
                found.append(LocalModel(url: url, displayName: "Whisper \(base.capitalized)", sizeBytes: size))
            }
        }
        models = found.sorted { $0.sizeBytes < $1.sizeBytes }
    }

    func downloadSmall() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        session.downloadTask(with: Self.smallURL).resume()
    }

    func cancelDownload() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        isDownloading = false
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.smallBytes
            self.downloadProgress = min(Double(totalBytesWritten) / Double(total), 1)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            do {
                try AppPaths.prepare()
                if FileManager.default.fileExists(atPath: self.destination.path) {
                    try FileManager.default.removeItem(at: self.destination)
                }
                try FileManager.default.moveItem(at: location, to: self.destination)
                self.isDownloading = false
                self.downloadProgress = 1
                self.refresh()
            } catch {
                self.isDownloading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.isDownloading = false
            if (error as NSError).code != NSURLErrorCancelled { self.errorMessage = error.localizedDescription }
        }
    }
}
