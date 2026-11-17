import Foundation
import AVFoundation
import AppKit

enum StopFramesError: LocalizedError {
    case imageGenerationFailed
    case pythonNotFound
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageGenerationFailed:
            return "Не удалось извлечь стоп-кадр из видео."
        case .pythonNotFound:
            return "Модуль автоподбора стоп-кадров (StopFrames/.venv) не найден."
        case .scriptFailed(let msg):
            return msg
        }
    }
}

final class StopFramesEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcess: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let proc = runningProcess
        lock.unlock()
        proc?.terminate()
    }

    /// Мгновенный нативный стоп-кадр в полном разрешении (без Python)
    func captureFrame(from videoURL: URL, at seconds: Double) async throws -> StopFrameCapture {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let targetTime = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let cgImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: targetTime)]) { _, image, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: StopFramesError.imageGenerationFailed)
                }
            }
        }

        let baseDir = videoURL.deletingLastPathComponent()
            .appendingPathComponent("Стоп-кадры", isDirectory: true)
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let clockLabel = TranscriptSegment.clock(Int(max(0, seconds) * 1000)).replacingOccurrences(of: ":", with: "-")
        var dest = baseDir.appendingPathComponent("frame_\(clockLabel).jpg")
        var idx = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = baseDir.appendingPathComponent("frame_\(clockLabel)_\(idx).jpg")
            idx += 1
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpgData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94]) else {
            throw StopFramesError.imageGenerationFailed
        }
        try jpgData.write(to: dest, options: .atomic)

        return StopFrameCapture(
            path: dest.path,
            timestampSeconds: max(0, seconds),
            label: TranscriptSegment.clock(Int(max(0, seconds) * 1000))
        )
    }

    /// Автоподбор лучших кадров с лицами через установленный StopFrames (InsightFace + OpenCV)
    func runBestStopFrames(
        for videoURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (outputDir: URL, groups: [StopFramesPersonGroup]) {
        let stopFramesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/M24Workspace/StopFrames", isDirectory: true)
        let pythonURL = stopFramesDir.appendingPathComponent(".venv/bin/python")
        let scriptURL = stopFramesDir.appendingPathComponent("stopframes.py")

        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw StopFramesError.pythonNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    self.lock.lock(); self.cancelled = false; self.lock.unlock()

                    let process = Process()
                    process.executableURL = pythonURL
                    process.arguments = [scriptURL.path, videoURL.path, "--per-person", "4"]
                    process.currentDirectoryURL = stopFramesDir
                    process.qualityOfService = .userInitiated

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    self.lock.lock(); self.runningProcess = process; self.lock.unlock()
                    try process.run()

                    var pending = Data()
                    var finalOutputDir: String?
                    var finalPeople: [StopFramesPersonGroup] = []

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        pending.append(data)
                        while let nl = pending.firstIndex(of: 10) {
                            let lineData = pending.prefix(upTo: nl)
                            pending.removeSubrange(...nl)
                            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                                  let type = json["type"] as? String else { continue }
                            if type == "progress" {
                                let frac = json["fraction"] as? Double ?? 0
                                let msg = json["message"] as? String ?? "Анализ кадров..."
                                progress(frac, msg)
                            } else if type == "result" || type == "done" {
                                finalOutputDir = json["output_dir"] as? String
                                if let peopleArr = json["people"] as? [[String: Any]] {
                                    finalPeople = peopleArr.compactMap { item in
                                        guard let name = item["name"] as? String,
                                              let frames = item["frames"] as? [String] else { return nil }
                                        let st = item["screen_time_seconds"] as? Double ?? 0
                                        return StopFramesPersonGroup(name: name, screenTimeSeconds: st, frames: frames)
                                    }
                                }
                            }
                        }
                    }

                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    self.lock.lock(); self.runningProcess = nil; let wasCancelled = self.cancelled; self.lock.unlock()
                    if wasCancelled {
                        throw ToolingError.cancelled
                    }
                    guard process.terminationStatus == 0 else {
                        let errText = String(data: stderrData, encoding: .utf8) ?? "Ошибка StopFrames"
                        throw StopFramesError.scriptFailed(String(errText.suffix(1200)))
                    }

                    let outURL = URL(fileURLWithPath: finalOutputDir ?? videoURL.deletingLastPathComponent().path)
                    continuation.resume(returning: (outURL, finalPeople))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
