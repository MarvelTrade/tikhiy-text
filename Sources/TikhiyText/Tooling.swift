import Foundation
import AVFoundation

enum ToolingError: LocalizedError {
    case missingTool(String)
    case processFailed(String)
    case missingOutput
    case invalidJSON
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingTool(let name): return "Не найден локальный инструмент \(name)."
        case .processFailed(let text): return text
        case .missingOutput: return "Модуль распознавания не создал результат."
        case .invalidJSON: return "Не удалось прочитать временные метки из результата."
        case .cancelled: return "Задача отменена."
        }
    }
}

final class TranscriptionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcess: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = runningProcess
        lock.unlock()
        process?.terminate()
    }

    func transcribe(
        source: URL,
        model: URL,
        language: TranscriptLanguage,
        speed: TranscriptionSpeed = .fast,
        duration: Double,
        progress: @escaping (Double, JobStatus) -> Void
    ) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    self.lock.lock(); self.cancelled = false; self.lock.unlock()
                    let result = try self.runPipeline(source: source, model: model, language: language, speed: speed, duration: duration, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runPipeline(
        source: URL,
        model: URL,
        language: TranscriptLanguage,
        speed: TranscriptionSpeed,
        duration: Double,
        progress: @escaping (Double, JobStatus) -> Void
    ) throws -> [TranscriptSegment] {
        guard let ffmpeg = executable(named: "ffmpeg") else { throw ToolingError.missingTool("ffmpeg") }
        guard let whisper = executable(named: "whisper-cli") else { throw ToolingError.missingTool("whisper-cli") }
        try AppPaths.prepare()

        let jobDir = AppPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobDir) }
        let wavURL = jobDir.appendingPathComponent("audio.wav")
        let outputBase = jobDir.appendingPathComponent("result")

        progress(0.02, .converting)
        _ = try run(
            executable: ffmpeg,
            arguments: ["-nostdin", "-y", "-threads", "4", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-progress", "pipe:2", wavURL.path]
        ) { line in
            if line.hasPrefix("out_time_ms="), let value = Double(line.split(separator: "=").last ?? "") {
                let seconds = value / 1_000_000
                let fraction = duration > 0 ? min(seconds / duration, 1) : 0
                progress(0.02 + fraction * 0.16, .converting)
            }
        }

        try checkCancelled()
        progress(0.20, .transcribing)
        let beam = String(speed.beamSize)
        _ = try run(
            executable: whisper,
            arguments: [
                "-m", model.path, "-f", wavURL.path,
                "-l", language.rawValue,
                "-t", "4", "-p", "1",
                "-fa",
                "-bs", beam, "-bo", beam,
                "-oj", "-of", outputBase.path, "-pp"
            ]
        ) { line in
            if let percent = Self.progressPercent(in: line) {
                progress(0.20 + min(max(percent / 100, 0), 1) * 0.78, .transcribing)
            }
        }

        try checkCancelled()
        let jsonURL = outputBase.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { throw ToolingError.missingOutput }
        let data = try Data(contentsOf: jsonURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = root["transcription"] as? [[String: Any]] else {
            throw ToolingError.invalidJSON
        }

        let segments: [TranscriptSegment] = rawSegments.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            let offsets = item["offsets"] as? [String: Any]
            let start = offsets?["from"] as? Int ?? 0
            let end = offsets?["to"] as? Int ?? start
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return TranscriptSegment(startMS: start, endMS: end, text: cleaned)
        }
        progress(1, .completed)
        return segments
    }

    private func run(executable: URL, arguments: [String], onLine: @escaping (String) -> Void) throws -> String {
        try checkCancelled()
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        process.standardOutput = output
        process.standardError = output

        lock.lock(); runningProcess = process; lock.unlock()
        try process.run()

        var collected = Data()
        var pending = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let lineData = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        lock.lock(); runningProcess = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw ToolingError.cancelled }
        guard process.terminationStatus == 0 else {
            let text = String(data: collected, encoding: .utf8) ?? "Неизвестная ошибка"
            throw ToolingError.processFailed(String(text.suffix(1800)))
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    private func checkCancelled() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ToolingError.cancelled }
    }

    private func executable(named name: String) -> URL? {
        var candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let bundleBin = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)").path {
            candidates.insert(bundleBin, at: 0)
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func progressPercent(in line: String) -> Double? {
        let patterns = [#"progress\s*=\s*(\d+)%"#, #"whisper_print_progress_callback:\s*progress\s*=\s*(\d+)%"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return Double(line[range])
        }
        return nil
    }
}

enum MediaInfo {
    static func duration(of url: URL) -> Double {
        let semaphore = DispatchSemaphore(value: 0)
        var value = 0.0
        let asset = AVURLAsset(url: url)
        Task {
            if let duration = try? await asset.load(.duration) { value = duration.seconds }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 4)
        return value.isFinite ? max(0, value) : 0
    }
}
