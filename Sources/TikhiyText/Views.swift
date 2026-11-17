import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.18, green: 0.82, blue: 0.62)
private let canvas = Color(red: 0.043, green: 0.059, blue: 0.090)
private let cardSurface = Color(red: 0.071, green: 0.098, blue: 0.153)
private let panelSurface = Color(red: 0.055, green: 0.075, blue: 0.125)
private let cardBorder = Color.white.opacity(0.08)
private let rimGlow = Color(red: 0.18, green: 0.82, blue: 0.62).opacity(0.20)

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var isDropTarget = false

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 760 {
                VStack(spacing: 0) {
                    CompactNavigationBar()
                    Divider()
                    mainContent
                }
            } else {
                HStack(spacing: 0) {
                    SidebarView().frame(width: 220)
                    Divider()
                    mainContent
                }
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 400, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let url = URL(string: text) else { return }
                    Task { @MainActor in state.importFiles([url]) }
                }
            }
            return true
        }
        .alert("Расшифровщик", isPresented: Binding(get: { state.notice != nil }, set: { if !$0 { state.notice = nil } })) {
            Button("Хорошо") { state.notice = nil }
        } message: { Text(state.notice ?? "") }
    }

    private var mainContent: some View {
        ZStack {
            canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar()
                if let job = state.selectedJob {
                    JobDetailView(job: job)
                } else {
                    HomeView(isDropTarget: $isDropTarget)
                }
            }
        }
    }
}

struct CompactNavigationBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Главная") { state.selectedID = nil }
                if !state.jobs.isEmpty { Divider() }
                ForEach(state.jobs) { job in
                    Button(job.title) { state.selectedID = job.id }
                }
            } label: {
                Label(state.selectedJob?.title ?? "Главная", systemImage: "sidebar.left")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 8)
            Button("Открыть файл", systemImage: "plus", action: state.openPanel)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(panelSurface)
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Расшифровщик").font(.headline)
                    Text("Локальная расшифровка").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)

            Button {
                state.selectedID = nil
            } label: {
                Label("Главная", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .background(state.selectedID == nil ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(state.selectedID == nil ? accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 10)

            HStack {
                Text("НЕДАВНИЕ").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(state.jobs.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)

            List(selection: $state.selectedID) {
                ForEach(state.jobs) { job in
                    SidebarJobRow(job: job).tag(job.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.5)

            VStack(spacing: 6) {
                Button(action: state.exportAllTranscripts) {
                    Label("Достать все расшифровки", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)

                Button(action: state.openDataFolder) {
                    Label("Папка данных и кэша", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)

                Button {
                    confirmClear = true
                } label: {
                    HStack {
                        Label("Очистить кэш", systemImage: "trash")
                        Spacer()
                        Text(state.cacheSizeLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Button(action: state.openPanel) {
                Label("Открыть файл", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Text("Антон Белый")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 10)
        }
        .background(panelSurface)
        .confirmationDialog("Очистка кэша и данных", isPresented: $confirmClear) {
            Button("Очистить только временный кэш") {
                state.clearCacheAndHistory(keepHistory: true)
            }
            Button("Удалить кэш и всю историю", role: .destructive) {
                state.clearCacheAndHistory(keepHistory: false)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Временные аудиофайлы и история занимают \(state.cacheSizeLabel). Скачанные модели Whisper не удаляются.")
        }
    }
}

struct SidebarJobRow: View {
    let job: TranscriptJob
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.isVideo ? "play.rectangle.fill" : "waveform")
                .foregroundStyle(job.status == .completed ? .green : accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1).truncationMode(.middle).font(.subheadline.weight(.medium))
                Text(job.status.title).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Удалить из списка", role: .destructive) {
                AppStateHolder.shared?.deleteJob(job.id)
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var library: ModelLibrary

    init() {
        let appState = AppStateHolder.shared!
        _library = ObservedObject(wrappedValue: appState.modelLibrary)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) { title; Spacer(); controls }
          VStack(alignment: .leading, spacing: 8) { title; controls }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(panelSurface.opacity(0.95))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: some View {
            Text(state.selectedJob?.title ?? "Новая расшифровка")
                .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Text("Язык").font(.caption).foregroundStyle(.secondary)
                Picker("Язык", selection: $state.language) {
                    ForEach(TranscriptLanguage.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 96)
            }
            HStack(spacing: 7) {
                Text("Скорость").font(.caption).foregroundStyle(.secondary)
                Picker("Скорость", selection: $state.speed) {
                    ForEach(TranscriptionSpeed.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 118)
            }
            Toggle("Автозапуск", isOn: $state.autoStartOnImport)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Начинать расшифровку сразу после добавления или перетаскивания файла")
            HStack(spacing: 7) {
                Text("Модель").font(.caption).foregroundStyle(.secondary)
                if library.models.isEmpty {
                    Text("Не установлена").font(.subheadline).foregroundStyle(.orange)
                } else {
                    Picker("Модель", selection: $state.selectedModelPath) {
                        ForEach(library.models) { model in
                            Text("\(model.displayName) · \(model.sizeLabel)").tag(model.url.path)
                        }
                    }.labelsHidden().frame(minWidth: 120, idealWidth: 180, maxWidth: 190)
                }
            }
        }
    }
}

// Lets TopBar observe the same library before the EnvironmentObject is resolved.
@MainActor final class AppStateHolder {
    static var shared: AppState!
}

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var library: ModelLibrary
    @Binding var isDropTarget: Bool

    init(isDropTarget: Binding<Bool>) {
        _isDropTarget = isDropTarget
        _library = ObservedObject(wrappedValue: AppStateHolder.shared!.modelLibrary)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Превратите запись в текст").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Аудио и видео остаются на этом Mac. Никаких аккаунтов и облачной отправки.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                ImportZone(isDropTarget: $isDropTarget)

                if library.models.isEmpty || library.isDownloading {
                    ModelDownloadCard(library: library)
                }

                if !state.jobs.isEmpty {
                    Text("Последние расшифровки").font(.title2.bold()).padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(state.jobs.prefix(6)) { job in
                            RecentCard(job: job).onTapGesture { state.selectedID = job.id }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

struct ImportZone: View {
    @EnvironmentObject var state: AppState
    @Binding var isDropTarget: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 42)).foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            Text("Перетащите аудио или видео сюда").font(.title2.bold())
            Text("M4A, MP3, WAV, MP4, MOV, M4V, MKV").foregroundStyle(.secondary)
            Text("Расшифровка начнётся автоматически")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Button("Открыть файл", action: state.openPanel)
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity).frame(height: 245)
        .background(isDropTarget ? accent.opacity(0.15) : cardSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isDropTarget ? accent : Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [8]))
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let url = URL(string: text) else { return }
                    Task { @MainActor in state.importFiles([url]) }
                }
            }
            return true
        }
    }
}

struct ModelDownloadCard: View {
    @ObservedObject var library: ModelLibrary
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "cpu.fill").font(.system(size: 28)).foregroundStyle(accent)
                .frame(width: 54, height: 54).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Локальная модель Whisper Small").font(.headline)
                Text("Около 466 МБ · рекомендуется для русского на M1 с 8 ГБ RAM")
                    .font(.subheadline).foregroundStyle(.secondary)
                if library.isDownloading { ProgressView(value: library.downloadProgress).frame(maxWidth: 320) }
            }
            Spacer()
            if library.isDownloading {
                Button("Отменить", action: library.cancelDownload)
            } else {
                Button("Скачать один раз", action: library.downloadSmall).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }
}

struct RecentCard: View {
    let job: TranscriptJob
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: job.isVideo ? "play.rectangle.fill" : "waveform")
                    .font(.title2).foregroundStyle(accent)
                Spacer()
                StatusBadge(status: job.status)
            }
            Text(job.title).font(.headline).lineLimit(2)
            Text(job.segments.first?.text ?? job.sourceURL.lastPathComponent)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(TranscriptSegment.clock(Int(job.durationSeconds * 1000)))
                Spacer()
                Text(job.updatedAt, style: .date)
            }.font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        .contentShape(Rectangle())
    }
}

struct JobDetailView: View {
    @EnvironmentObject var state: AppState
    let job: TranscriptJob

    var body: some View {
        Group {
            if job.status == .completed {
                TranscriptResultView(job: job)
            } else {
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: job.isVideo ? "play.rectangle.fill" : "waveform.circle.fill")
                        .font(.system(size: 72)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                    VStack(spacing: 7) {
                        Text(job.sourceURL.lastPathComponent).font(.title2.bold()).lineLimit(2)
                        Text("\(job.isVideo ? "Видео" : "Аудио") · \(TranscriptSegment.clock(Int(job.durationSeconds * 1000)))")
                            .foregroundStyle(.secondary)
                    }
                    if [.queued, .converting, .transcribing].contains(job.status) {
                        VStack(spacing: 10) {
                            ProgressView(value: job.progress).frame(maxWidth: 380)
                            Text("\(job.status.title) · \(Int(job.progress * 100))%")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Отменить задачу", role: .destructive, action: state.cancelActive)
                        }
                    } else {
                        if let error = job.errorMessage {
                            Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 600)
                        }
                        Button("Расшифровать", action: state.enqueueSelected)
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(state.selectedModel == nil)
                        if job.isVideo {
                            StopFramesPanelView(job: job, currentSeconds: 0)
                                .frame(maxWidth: 360)
                                .padding(16)
                                .background(cardSurface, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(cardBorder, lineWidth: 1))
                        }
                        Text("Исходный файл не изменяется. Обработка выполняется локально.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(40)
            }
        }
    }
}

struct TranscriptResultView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var playerController = PlayerController()
    @State private var searchQuery = ""
    @State private var showVideoPreview = false
    let job: TranscriptJob

    private var filteredSegments: [TranscriptSegment] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return job.segments }
        return job.segments.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < 820 {
                VStack(spacing: 0) {
                    transcriptContent
                    Divider()
                    compactExportPanel
                }
            } else {
                HStack(spacing: 0) {
                    transcriptContent
                    Divider()
                    exportPanel
                }
            }
        }
        .onAppear { playerController.load(job.sourceURL) }
        .onChange(of: job.sourcePath) { _, _ in playerController.load(job.sourceURL) }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompactPlayerCard(
                controller: playerController,
                job: job,
                showVideoPreview: $showVideoPreview,
                onCaptureFrame: { state.captureFrame(at: playerController.currentTime) }
            )

            if showVideoPreview && job.isVideo {
                NativePlayerView(player: playerController.player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cardBorder, lineWidth: 1))
            }

            HStack(spacing: 10) {
                StatusBadge(status: job.status)
                Text("\(job.segments.count) фрагментов")
                if let elapsed = job.elapsedSeconds {
                    Text("· за \(elapsed.formatted(.number.precision(.fractionLength(1)))) с")
                }
                Spacer()
                Button("Копировать всё", systemImage: "doc.on.doc", action: state.copyAllText)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Файл", action: state.revealSource)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск по расшифровке…", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(cardSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cardBorder, lineWidth: 1))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let currentMS = Int(playerController.currentTime * 1000)
                    ForEach(filteredSegments) { segment in
                        let isActive = currentMS >= segment.startMS && currentMS <= segment.endMS
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                playerController.seek(milliseconds: segment.startMS)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(TranscriptSegment.clock(segment.startMS))
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(isActive ? .white : accent)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(isActive ? accent : accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                        .frame(width: 64, alignment: .leading)
                                    Text(segment.text)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)

                            if job.isVideo {
                                Button {
                                    state.captureFrame(at: Double(segment.startMS) / 1000.0)
                                } label: {
                                    Image(systemName: "camera.viewfinder")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Снять стоп-кадр на этом моменте")
                            }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .background(isActive ? accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var exportPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Экспорт").font(.title3.bold())
                Text("Файл будет сохранён рядом с оригиналом.").font(.caption).foregroundStyle(.secondary)
                ForEach(ExportFormat.allCases) { format in
                    Button { state.export(format) } label: {
                        HStack {
                            Image(systemName: (format == .srt || format == .vtt) ? "captions.bubble" : "doc.text")
                            Text(format.rawValue)
                            Spacer()
                            Image(systemName: "arrow.down.doc")
                        }.padding(.vertical, 3)
                    }.buttonStyle(.bordered)
                }

                if job.isVideo {
                    Divider()
                    StopFramesPanelView(job: job, currentSeconds: playerController.currentTime)
                }

                Divider()
                Text("Параметры").font(.headline)
                LabeledContent("Язык", value: job.language.title)
                LabeledContent("Модель", value: job.modelName)
                LabeledContent("Длительность", value: TranscriptSegment.clock(Int(job.durationSeconds * 1000)))

                Button("Перезапустить", systemImage: "arrow.clockwise", action: state.retranscribeSelected)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(width: 280)
        .background(panelSurface)
    }

    private var compactExportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Экспорт").font(.headline)
                Spacer()
                ForEach(ExportFormat.allCases) { format in
                    Button(format.rawValue) { state.export(format) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if job.isVideo {
                    Button("📸 Кадр") { state.captureFrame(at: playerController.currentTime) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(panelSurface)
    }
}

struct StopFramesPanelView: View {
    @EnvironmentObject var state: AppState
    let job: TranscriptJob
    let currentSeconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Стоп-кадры").font(.title3.bold())

            Button {
                state.captureFrame(at: currentSeconds)
            } label: {
                Label("Кадр сейчас (\(TranscriptSegment.clock(Int(currentSeconds * 1000))))", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if state.isRunningStopFrames {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: state.stopFramesProgress)
                    HStack {
                        Text(state.stopFramesStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Стоп", action: state.cancelStopFrames).buttonStyle(.plain).font(.caption2).foregroundStyle(.red)
                    }
                }
            } else {
                Button {
                    state.runBestStopFrames()
                } label: {
                    Label("Лучшие кадры (ИИ-лица)", systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            let manual = state.capturedFrames[job.id] ?? []
            if !manual.isEmpty {
                Text("Снятые кадры").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(manual.prefix(6)) { item in
                        StopFrameThumb(url: item.url, label: item.label)
                    }
                }
            }

            let aiGroups = state.stopFramesGroups[job.id] ?? []
            if !aiGroups.isEmpty {
                HStack {
                    Text("Отобрано ИИ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let dir = state.stopFramesOutputDir[job.id] {
                        Button("Папка ↗") { NSWorkspace.shared.open(dir) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                    }
                }
                ForEach(aiGroups) { group in
                    Text("\(group.title) (\(Int(group.screenTimeSeconds))с)")
                        .font(.caption2).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(group.frameURLs.prefix(4), id: \.self) { url in
                            StopFrameThumb(url: url, label: url.deletingPathExtension().lastPathComponent)
                        }
                    }
                }
            }
        }
    }
}

struct StopFrameThumb: View {
    @EnvironmentObject var state: AppState
    let url: URL
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10, design: .monospaced)).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button { state.copyImageToClipboard(url) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }.buttonStyle(.plain).help("Копировать кадр")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder").font(.system(size: 10))
                }.buttonStyle(.plain).help("Показать в Finder")
            }
        }
        .padding(5)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cardBorder, lineWidth: 1))
    }
}

struct CompactPlayerCard: View {
    @ObservedObject var controller: PlayerController
    let job: TranscriptJob
    @Binding var showVideoPreview: Bool
    let onCaptureFrame: () -> Void

    private let rates: [Float] = [1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: job.isVideo ? "play.rectangle.fill" : "waveform.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.sourceURL.lastPathComponent)
                        .font(.headline).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    Text(job.isVideo ? "Видео · Плеер и стоп-кадры" : "Исходная аудиозапись")
                        .font(.caption).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                if job.isVideo {
                    Button {
                        withAnimation { showVideoPreview.toggle() }
                    } label: {
                        Label(showVideoPreview ? "Скрыть видео" : "Видео", systemImage: showVideoPreview ? "eye.slash" : "play.tv")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: onCaptureFrame) {
                        Label("Стоп-кадр", systemImage: "camera.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Menu {
                    ForEach(rates, id: \.self) { rate in
                        Button("\(rate.formatted(.number.precision(.fractionLength(0...2))))x") {
                            controller.setRate(rate)
                        }
                    }
                } label: {
                    Text("\(controller.playbackRate.formatted(.number.precision(.fractionLength(0...2))))x")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 12) {
                Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button(action: controller.togglePlayback) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 26, height: 26)
                }
                Text(clock(controller.currentTime))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
                    .frame(width: 44)
                Slider(value: Binding(get: { controller.currentTime }, set: { controller.seek(seconds: $0) }), in: 0...max(controller.duration, 0.1))
                    .tint(.white)
                Text(clock(controller.duration))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
                    .frame(width: 44)
                Button { controller.skip(10) } label: { Image(systemName: "goforward.10") }
            }
            .buttonStyle(.plain).foregroundStyle(.white)
        }
        .padding(17)
        .background(Color(red: 0.10, green: 0.115, blue: 0.16), in: RoundedRectangle(cornerRadius: 17))
    }

    private func clock(_ seconds: Double) -> String {
        TranscriptSegment.clock(Int(max(0, seconds) * 1000))
    }
}

struct StatusBadge: View {
    let status: JobStatus
    var color: Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .queued, .converting, .transcribing: return accent
        case .ready: return .gray
        }
    }
    var body: some View {
        Text(status.title).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.10), in: Capsule())
    }
}
