import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var jobs: [TranscriptJob] = []
    @Published var selectedID: UUID?
    @Published var language: TranscriptLanguage = .russian
    @Published var speed: TranscriptionSpeed = .fast
    @Published var selectedModelPath = ""
    @Published var notice: String?
    @Published var isProcessing = false
    @Published var autoStartOnImport = true

    // Стоп-кадры (мгновенные и автоподбор ИИ)
    @Published var capturedFrames: [UUID: [StopFrameCapture]] = [:]
    @Published var stopFramesGroups: [UUID: [StopFramesPersonGroup]] = [:]
    @Published var stopFramesOutputDir: [UUID: URL] = [:]
    @Published var isRunningStopFrames = false
    @Published var stopFramesProgress = 0.0
    @Published var stopFramesStatus = ""

    let modelLibrary = ModelLibrary()
    private let engine = TranscriptionEngine()
    private let stopFramesEngine = StopFramesEngine()
    private var queue: [UUID] = []

    init() {
        loadHistory()
        if let first = modelLibrary.models.first { selectedModelPath = first.url.path }
    }

    var selectedJob: TranscriptJob? {
        get { jobs.first(where: { $0.id == selectedID }) }
        set {
            guard let value = newValue, let index = jobs.firstIndex(where: { $0.id == value.id }) else { return }
            jobs[index] = value
        }
    }

    var selectedModel: LocalModel? {
        modelLibrary.models.first(where: { $0.url.path == selectedModelPath }) ?? modelLibrary.models.first
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Выберите аудио или видео"
        panel.prompt = "Открыть"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "m4a")!, .mp3, .wav, .mpeg4Movie, .quickTimeMovie,
            UTType(filenameExtension: "m4v")!, UTType(filenameExtension: "mkv")!,
            UTType(filenameExtension: "aac")!, UTType(filenameExtension: "ogg")!
        ]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        let allowed = Set(["m4a", "mp3", "wav", "mp4", "mov", "m4v", "mkv", "aac", "ogg"])
        var importedIDs: [UUID] = []
        for url in urls where allowed.contains(url.pathExtension.lowercased()) {
            if let existing = jobs.first(where: { $0.sourcePath == url.path }) {
                selectedID = existing.id
                notice = existing.status == .completed
                    ? "Этот файл уже расшифрован. Открыт сохранённый результат."
                    : "Этот файл уже есть в списке задач."
                continue
            }
            let duration = MediaInfo.duration(of: url)
            let job = TranscriptJob(url: url, language: language, modelName: selectedModel?.displayName ?? "", duration: duration)
            jobs.insert(job, at: 0)
            selectedID = job.id
            importedIDs.append(job.id)
        }
        saveHistory()
        if autoStartOnImport, selectedModel != nil {
            importedIDs.forEach(enqueue)
        }
    }

    func enqueueSelected() {
        guard let id = selectedID else { return }
        enqueue(id)
    }

    private func enqueue(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard selectedModel != nil else { notice = "Сначала скачайте локальную модель."; return }
        guard !queue.contains(id), jobs[index].status != .transcribing, jobs[index].status != .converting else {
            notice = "Эта задача уже выполняется или стоит в очереди."
            return
        }
        if jobs[index].status == .completed {
            notice = "Расшифровка уже готова. Повторный запуск заблокирован."
            return
        }
        jobs[index].language = language
        jobs[index].modelName = selectedModel?.displayName ?? ""
        jobs[index].status = .queued
        jobs[index].progress = 0
        jobs[index].errorMessage = nil
        queue.append(id)
        saveHistory()
        processNextIfNeeded()
    }

    func cancelActive() {
        guard let id = selectedID else { return }
        if let queueIndex = queue.firstIndex(of: id), jobs.first(where: { $0.id == id })?.status == .queued {
            queue.remove(at: queueIndex)
            update(id) { $0.status = .cancelled; $0.errorMessage = nil }
            return
        }
        engine.cancel()
    }

    func export(_ format: ExportFormat) {
        guard let job = selectedJob, job.status == .completed else { return }
        let base = job.sourceURL.deletingPathExtension()
        let destination = availableExportURL(base: base, extensionName: format.extensionName)
        do {
            try format.render(job).write(to: destination, atomically: true, encoding: .utf8)
            notice = "Сохранено рядом с исходником: \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { notice = "Не удалось сохранить: \(error.localizedDescription)" }
    }

    private func availableExportURL(base: URL, extensionName: String) -> URL {
        let direct = base.appendingPathExtension(extensionName)
        guard FileManager.default.fileExists(atPath: direct.path) else { return direct }
        let named = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + " — расшифровка")
            .appendingPathExtension(extensionName)
        guard FileManager.default.fileExists(atPath: named.path) else { return named }
        for number in 2...999 {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent(base.lastPathComponent + " — расшифровка \(number)")
                .appendingPathExtension(extensionName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + " — расшифровка \(UUID().uuidString.prefix(6))")
            .appendingPathExtension(extensionName)
    }

    func revealSource() {
        guard let job = selectedJob else { return }
        NSWorkspace.shared.activateFileViewerSelecting([job.sourceURL])
    }

    var cacheSizeLabel: String {
        let fm = FileManager.default
        var bytes: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: AppPaths.history.path),
           let size = attrs[.size] as? Int64 {
            bytes += size
        }
        if let enumerator = fm.enumerator(at: AppPaths.work, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                    bytes += size
                }
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func openDataFolder() {
        try? AppPaths.prepare()
        NSWorkspace.shared.open(AppPaths.root)
    }

    func exportAllTranscripts() {
        let completed = jobs.filter { $0.status == .completed && !$0.segments.isEmpty }
        guard !completed.isEmpty else {
            notice = "Нет готовых расшифровок для экспорта."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Выберите папку, куда выгрузить все расшифровки"
        panel.prompt = "Выгрузить сюда"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var count = 0
        for job in completed {
            let safeName = job.title.replacingOccurrences(of: "/", with: "-")
            let txtURL = folder.appendingPathComponent("\(safeName).txt")
            let srtURL = folder.appendingPathComponent("\(safeName).srt")
            try? ExportFormat.txt.render(job).write(to: txtURL, atomically: true, encoding: .utf8)
            try? ExportFormat.srt.render(job).write(to: srtURL, atomically: true, encoding: .utf8)
            count += 1
        }
        notice = "Выгружено \(count) расшифровок (TXT + SRT) в папку \(folder.lastPathComponent)."
        NSWorkspace.shared.open(folder)
    }

    func clearCacheAndHistory(keepHistory: Bool = false) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: AppPaths.work, includingPropertiesForKeys: nil) {
            for item in contents {
                try? fm.removeItem(at: item)
            }
        }
        if !keepHistory {
            selectedID = nil
            jobs.removeAll()
            queue.removeAll()
            capturedFrames.removeAll()
            stopFramesGroups.removeAll()
            stopFramesOutputDir.removeAll()
            try? fm.removeItem(at: AppPaths.history)
            notice = "Кэш и история полностью очищены. Модели Whisper сохранены."
        } else {
            notice = "Временный кэш аудио/файлов очищен."
        }
        objectWillChange.send()
    }

    func copyAllText() {
        guard let job = selectedJob, !job.segments.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.fullText, forType: .string)
        notice = "Весь текст расшифровки скопирован в буфер обмена."
    }

    func deleteJob(_ id: UUID) {
        if selectedID == id { selectedID = nil }
        jobs.removeAll { $0.id == id }
        queue.removeAll { $0 == id }
        saveHistory()
    }

    func retranscribeSelected() {
        guard let id = selectedID, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = .ready
        jobs[index].progress = 0
        jobs[index].segments = []
        jobs[index].errorMessage = nil
        enqueue(id)
    }

    func captureFrame(at seconds: Double) {
        guard let job = selectedJob, job.isVideo else { return }
        let jobID = job.id
        let url = job.sourceURL
        Task {
            do {
                let capture = try await stopFramesEngine.captureFrame(from: url, at: seconds)
                var list = self.capturedFrames[jobID] ?? []
                list.insert(capture, at: 0)
                self.capturedFrames[jobID] = list
                self.notice = "Стоп-кадр сохранён: \(capture.url.lastPathComponent)"
            } catch {
                self.notice = "Ошибка стоп-кадра: \(error.localizedDescription)"
            }
        }
    }

    func runBestStopFrames() {
        guard let job = selectedJob, job.isVideo, !isRunningStopFrames else { return }
        let jobID = job.id
        let url = job.sourceURL
        isRunningStopFrames = true
        stopFramesProgress = 0.02
        stopFramesStatus = "Запуск анализа кадров..."
        Task {
            do {
                let (outDir, groups) = try await stopFramesEngine.runBestStopFrames(for: url) { frac, msg in
                    Task { @MainActor in
                        self.stopFramesProgress = frac
                        self.stopFramesStatus = msg
                    }
                }
                self.stopFramesOutputDir[jobID] = outDir
                self.stopFramesGroups[jobID] = groups
                self.isRunningStopFrames = false
                self.stopFramesProgress = 1.0
                let count = groups.reduce(0) { $0 + $1.frames.count }
                self.stopFramesStatus = count > 0 ? "Отобрано кадров: \(count)" : "Подходящие лица не найдены"
            } catch ToolingError.cancelled {
                self.isRunningStopFrames = false
                self.stopFramesStatus = "Отменено"
            } catch {
                self.isRunningStopFrames = false
                self.notice = "Ошибка автоподбора: \(error.localizedDescription)"
            }
        }
    }

    func cancelStopFrames() {
        stopFramesEngine.cancel()
    }

    func copyImageToClipboard(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        notice = "Кадр скопирован в буфер обмена."
    }

    private func processNextIfNeeded() {
        guard !isProcessing, let id = queue.first else { return }
        queue.removeFirst()
        guard let index = jobs.firstIndex(where: { $0.id == id }), let model = selectedModel else { return }
        isProcessing = true
        let source = jobs[index].sourceURL
        let selectedLanguage = jobs[index].language
        let selectedSpeed = speed
        let duration = jobs[index].durationSeconds
        let started = Date()

        Task {
            do {
                let segments = try await engine.transcribe(source: source, model: model.url, language: selectedLanguage, speed: selectedSpeed, duration: duration) { value, status in
                    Task { @MainActor in self.update(id) { $0.progress = value; $0.status = status } }
                }
                update(id) {
                    $0.segments = segments
                    $0.progress = 1
                    $0.status = .completed
                    $0.elapsedSeconds = Date().timeIntervalSince(started)
                    $0.updatedAt = Date()
                }
            } catch ToolingError.cancelled {
                update(id) { $0.status = .cancelled; $0.errorMessage = nil; $0.updatedAt = Date() }
            } catch {
                update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription; $0.updatedAt = Date() }
            }
            isProcessing = false
            saveHistory()
            processNextIfNeeded()
        }
    }

    private func update(_ id: UUID, mutation: (inout TranscriptJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
        jobs[index].updatedAt = Date()
    }

    private func loadHistory() {
        try? AppPaths.prepare()
        guard let data = try? Data(contentsOf: AppPaths.history),
              let decoded = try? JSONDecoder().decode([TranscriptJob].self, from: data) else { return }
        jobs = decoded.map { item in
            var job = item
            if [.queued, .converting, .transcribing].contains(job.status) {
                job.status = .cancelled
                job.errorMessage = "Задача была прервана при закрытии приложения."
            }
            return job
        }
    }

    private func saveHistory() {
        try? AppPaths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(jobs) { try? data.write(to: AppPaths.history, options: .atomic) }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "TXT", markdown = "Markdown", srt = "SRT", vtt = "VTT"
    var id: String { rawValue }
    var extensionName: String { self == .markdown ? "md" : rawValue.lowercased() }

    func render(_ job: TranscriptJob) -> String {
        switch self {
        case .txt:
            return job.segments.map { "[\($0.timestamp)]  \($0.text)" }.joined(separator: "\n") + "\n"
        case .markdown:
            let header = "# \(job.title)\n\nИсточник: `\(job.sourceURL.lastPathComponent)`  \nЯзык: \(job.language.title)  \nМодель: \(job.modelName)\n\n"
            return header + job.segments.map { "**[\($0.timestamp)]** \($0.text)" }.joined(separator: "\n\n") + "\n"
        case .srt:
            return job.segments.enumerated().map { index, segment in
                "\(index + 1)\n\(TranscriptSegment.srtClock(segment.startMS)) --> \(TranscriptSegment.srtClock(segment.endMS))\n\(segment.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = job.segments.map { segment in
                let start = TranscriptSegment.srtClock(segment.startMS).replacingOccurrences(of: ",", with: ".")
                let end = TranscriptSegment.srtClock(segment.endMS).replacingOccurrences(of: ",", with: ".")
                return "\(start) --> \(end)\n\(segment.text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        }
    }
}
