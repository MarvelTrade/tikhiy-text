import Foundation

enum TranscriptLanguage: String, Codable, CaseIterable, Identifiable {
    case russian = "ru"
    case automatic = "auto"

    var id: String { rawValue }
    var title: String { self == .russian ? "Русский" : "Авто" }
}

enum TranscriptionSpeed: String, Codable, CaseIterable, Identifiable {
    case fast = "fast"
    case balanced = "balanced"
    case accurate = "accurate"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Быстро (M1)"
        case .balanced: return "Баланс"
        case .accurate: return "Точно"
        }
    }

    var beamSize: Int {
        switch self {
        case .fast: return 1
        case .balanced: return 2
        case .accurate: return 5
        }
    }
}

struct StopFrameCapture: Codable, Identifiable, Hashable {
    var id = UUID()
    let path: String
    let timestampSeconds: Double
    let label: String
    var url: URL { URL(fileURLWithPath: path) }
}

struct StopFramesPersonGroup: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let screenTimeSeconds: Double
    let frames: [String]
    var title: String { name.replacingOccurrences(of: "_", with: " ") }
    var frameURLs: [URL] { frames.map { URL(fileURLWithPath: $0) } }
}

enum JobStatus: String, Codable {
    case ready, queued, converting, transcribing, completed, failed, cancelled

    var title: String {
        switch self {
        case .ready: return "Готов к запуску"
        case .queued: return "В очереди"
        case .converting: return "Подготовка аудио"
        case .transcribing: return "Расшифровка"
        case .completed: return "Готово"
        case .failed: return "Ошибка"
        case .cancelled: return "Отменено"
        }
    }
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    let startMS: Int
    let endMS: Int
    let text: String

    var timestamp: String { "\(Self.clock(startMS)) — \(Self.clock(endMS))" }

    static func clock(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func srtClock(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = (value % 3_600_000) / 60_000
        let seconds = (value % 60_000) / 1_000
        let millis = value % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}

struct TranscriptJob: Codable, Identifiable, Hashable {
    let id: UUID
    let sourcePath: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var status: JobStatus
    var progress: Double
    var language: TranscriptLanguage
    var modelName: String
    var durationSeconds: Double
    var elapsedSeconds: Double?
    var segments: [TranscriptSegment]
    var errorMessage: String?

    init(url: URL, language: TranscriptLanguage, modelName: String, duration: Double) {
        id = UUID()
        sourcePath = url.path
        title = url.deletingPathExtension().lastPathComponent
        createdAt = Date()
        updatedAt = Date()
        status = .ready
        progress = 0
        self.language = language
        self.modelName = modelName
        durationSeconds = duration
        elapsedSeconds = nil
        segments = []
        errorMessage = nil
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var isVideo: Bool { ["mp4", "mov", "m4v", "mkv"].contains(sourceURL.pathExtension.lowercased()) }
    var fullText: String { segments.map(\.text).joined(separator: "\n") }
}

struct LocalModel: Identifiable, Hashable {
    let url: URL
    let displayName: String
    let sizeBytes: Int64
    var id: String { url.path }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

enum AppPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TikhiyText", isDirectory: true)
    static let models = root.appendingPathComponent("Models", isDirectory: true)
    static let history = root.appendingPathComponent("history.json")
    static let work = root.appendingPathComponent("Work", isDirectory: true)

    static func prepare() throws {
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
}
