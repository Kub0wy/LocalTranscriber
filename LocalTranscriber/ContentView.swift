import SwiftUI
import AppKit

@MainActor
final class TranscriptionProgress: ObservableObject {
    @Published var fraction = 0.0
    @Published var elapsed: TimeInterval = 0
    @Published var remaining: TimeInterval?
    @Published var details = ""
    @Published var currentAudioTime: TimeInterval = 0
    var audioDuration: TimeInterval = 0
    private var startedAt: Date?
    private var timer: Timer?
    private var acceptsUpdates = false

    func start(duration: TimeInterval) {
        audioDuration = duration; fraction = 0; elapsed = 0; remaining = nil; details = ""; currentAudioTime = 0
        acceptsUpdates = true
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func finish() { acceptsUpdates = false; fraction = 1; remaining = 0; tick(); timer?.invalidate(); timer = nil }
    func stop() { acceptsUpdates = false; tick(); timer?.invalidate(); timer = nil }
    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if fraction > 0.02 { remaining = max(0, elapsed / fraction - elapsed) }
    }
    func consume(_ line: String) {
        guard acceptsUpdates else { return }
        if let end = Self.endTime(from: line) {
            currentAudioTime = max(currentAudioTime, end)
            if audioDuration > 0 { fraction = min(0.995, currentAudioTime / audioDuration) }
        }
        if !Self.isSilencePlaceholder(line) {
            details += line + "\n"
        }
        tick()
    }

    private static func isSilencePlaceholder(_ line: String) -> Bool {
        let text: String
        if let close = line.lastIndex(of: "]") {
            text = String(line[line.index(after: close)...])
        } else {
            text = line
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return true }
        return cleaned.allSatisfy { ".…·-–—_ ".contains($0) }
    }
    private static func endTime(from line: String) -> Double? {
        // mlx-whisper prints timestamps without an hour field below 60 minutes
        // (MM:SS.mmm), then switches to HH:MM:SS.mmm. The old parser only
        // understood the first form, so progress stopped as soon as the
        // transcription crossed the one-hour mark.
        let pattern = #"-->\s+((?:\d{2}:)?\d{2}:\d{2}\.\d{3})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 2,
              let timestampRange = Range(match.range(at: 1), in: line) else { return nil }

        let timestamp = String(line[timestampRange])
        let clockAndMillis = timestamp.split(separator: ".", maxSplits: 1)
        guard clockAndMillis.count == 2,
              let milliseconds = Double(clockAndMillis[1]) else { return nil }

        let clock = clockAndMillis[0].split(separator: ":")
        switch clock.count {
        case 2: // MM:SS.mmm
            guard let minutes = Double(clock[0]), let seconds = Double(clock[1]) else { return nil }
            return minutes * 60 + seconds + milliseconds / 1000
        case 3: // HH:MM:SS.mmm
            guard let hours = Double(clock[0]), let minutes = Double(clock[1]), let seconds = Double(clock[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
        default:
            return nil
        }
    }
}

struct ContentView: View {
    @ObservedObject var managedRuntime: ManagedRuntimeSetupModel
    let showManagedSetup: () -> Void
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var progress = TranscriptionProgress()
    @State private var source: URL?
    @State private var destination: URL?
    @State private var format: OutputFormat = .txt
    @State private var timestamps = true
    @State private var timestampStyle: TimestampDisplayStyle = .startAndEnd
    @State private var timestampSpacing: TimestampSpacing = .automatic
    @State private var documentFontSize: Double = 9
    @State private var showTimestampOptions = false
    @State private var sourceLanguage = "auto"
    @State private var translate = false
    @State private var targetLanguage = "en"
    @State private var busy = false
    @State private var status = ""
    @State private var errorText: String?
    @State private var transcriptionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.spacing) {
                topArea
                transcriptionOptionsPanel
                languagePanel
                detailsPanel
                bottomActionArea
            }
            .padding(AppTheme.spacing)

            Divider()
            footer
        }
        .font(AppTheme.bodyFont)
        .controlSize(.small)
        .background(AppTheme.surface)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .onAppear {
            if status.isEmpty { status = settings.tr("Gotowy", "Ready") }
        }
        .onDisappear { cancelTranscription() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in cancelTranscription() }
        .onChange(of: settings.interfaceLanguage) { _, _ in if !busy { status = settings.tr("Gotowy", "Ready") } }
        .alert(settings.tr("Błąd", "Error"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("OK") { errorText = nil } } message: { Text(errorText ?? "") }
    }

    private var topArea: some View {
        VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
            HStack(alignment: .center, spacing: AppTheme.spacing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LocalTranscriber")
                        .font(AppTheme.titleFont)
                    Text(settings.tr("MLX Whisper • lokalnie na Apple Silicon", "MLX Whisper • private and local on Apple Silicon"))
                        .font(AppTheme.secondaryFont)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppTheme.spacing)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.settingsSymbolSize, weight: .medium))
                        .frame(width: AppTheme.settingsHitTarget, height: AppTheme.settingsHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(settings.tr("Ustawienia", "Settings"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: AppTheme.spacing) {
                selectionColumn(
                    title: settings.tr("ŹRÓDŁO", "SOURCE"),
                    value: source?.path ?? settings.tr("Nie wybrano pliku audio", "No audio file selected"),
                    action: chooseSource
                )
                selectionColumn(
                    title: settings.tr("MIEJSCE ZAPISU", "DESTINATION"),
                    value: destination?.path ?? settings.tr("Domyślnie: obok pliku źródłowego", "Default: next to source file"),
                    action: chooseDestination
                )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionColumn(title: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            StudioFlowSectionTitle(title: title)
            selectionSurface(value: value, action: action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionSurface(value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: AppTheme.compactSpacing) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppTheme.compactSpacing)
            Button(settings.tr("Wybierz…", "Choose…"), action: action)
                .disabled(busy)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .studioFlowRecessedSurface()
    }

    private var transcriptionOptionsPanel: some View {
        StudioFlowPanel(title: settings.tr("TRANSKRYPCJA", "TRANSCRIPTION")) {
            HStack(spacing: 20) {
                Picker(settings.tr("Format", "Format"), selection: $format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Toggle(settings.tr("Timestampy", "Timestamps"), isOn: $timestamps)
                    .disabled(format == .srt)
                Button(settings.tr("Opcje…", "Options…")) { showTimestampOptions.toggle() }
                    .disabled(format == .srt || !timestamps)
                    .popover(isPresented: $showTimestampOptions, arrowEdge: .bottom) {
                        TimestampOptionsView(style: $timestampStyle, spacing: $timestampSpacing, fontSize: $documentFontSize, format: format, settings: settings)
                    }
                Spacer()
            }
        }
    }

    private var languagePanel: some View {
        StudioFlowPanel(title: settings.tr("JĘZYK", "LANGUAGE")) {
            VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
                HStack(spacing: 20) {
                    Picker(settings.tr("Język źródłowy", "Source Language"), selection: $sourceLanguage) {
                        ForEach(SettingsStore.languages) { Text(localizedLanguageName($0.code, fallback: $0.name)).tag($0.code) }
                    }
                    .frame(width: 320)
                    Toggle(settings.tr("Tłumacz", "Translate"), isOn: $translate)
                    Picker(settings.tr("Język docelowy", "Target Language"), selection: $targetLanguage) {
                        Text(settings.tr("Angielski", "English")).tag("en")
                    }
                    .frame(width: 220)
                    .disabled(!translate)
                    Spacer()
                }
                Text(settings.tr("Whisper może tłumaczyć mowę na język angielski. Język docelowy staje się aktywny po włączeniu opcji Tłumacz.", "Whisper can translate speech into English. Target Language becomes active when Translate is enabled."))
                    .font(AppTheme.secondaryFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressArea: some View {
        VStack(spacing: 7) {
            ProgressView(value: progress.fraction)
                .tint(isProgressIdle ? Color.secondary : AppTheme.accent)
                .opacity(isProgressIdle ? 0.45 : 1)
            HStack {
                Text("\(Int(progress.fraction * 100))%").monospacedDigit()
                Spacer()
                Text(settings.tr("Upłynęło: ", "Elapsed: ") + (isProgressIdle ? "--:--" : clock(progress.elapsed)))
                Text(settings.tr("Pozostało: ", "Remaining: ") + (isProgressIdle ? "--:--" : (progress.remaining.map(clock) ?? "—")))
            }
            .font(AppTheme.secondaryFont)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: AppTheme.progressRowHeight)
        .background(AppTheme.recessed)
    }

    private var isProgressIdle: Bool {
        !busy && progress.fraction == 0 && progress.elapsed == 0
    }

    private var detailsPanel: some View {
        StudioFlowPanel(
            title: settings.tr("SZCZEGÓŁY", "DETAILS"),
            fillsAvailableHeight: true
        ) {
            TranscriptionDetailsContent(progress: progress, settings: settings)
        }
        .frame(minHeight: 140, maxHeight: .infinity)
    }

    private var bottomActionArea: some View {
        VStack(spacing: 0) {
            progressArea
            Divider()
            statusBar
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.separator, lineWidth: 0.5)
        }
    }

    private var statusBar: some View {
        HStack(spacing: AppTheme.compactSpacing) {
            if settings.runtimeMode == .managed && !managedRuntime.state.status.isReady {
                Text(settings.tr("Środowisko zarządzane nie jest gotowe.", "Managed runtime is not ready."))
                    .foregroundStyle(.orange)
                Button(settings.tr("Skonfiguruj", "Set Up"), action: showManagedSetup)
            } else {
                Text(status).foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                Button(settings.tr("ANULUJ", "CANCEL"), action: cancelTranscription)
                    .disabled(transcriptionTask?.isCancelled == true)
            }
            Button(settings.tr("TRANSKRYBUJ", "TRANSCRIBE"), action: startTranscription)
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || busy || (settings.runtimeMode == .managed && !managedRuntime.state.status.isReady))
        }
        .padding(.horizontal, AppTheme.spacing)
        .frame(height: AppTheme.footerHeight)
        .background(AppTheme.header)
    }

    private var footer: some View {
        HStack(spacing: AppTheme.spacing) {
            StudioFlowWebsiteButton(settings: settings)
            Spacer(minLength: AppTheme.spacing)
            BuyMeACoffeeButton(settings: settings)
        }
        .padding(.horizontal, AppTheme.spacing)
        .frame(height: AppTheme.footerHeight)
        .background(AppTheme.header)
    }

    private func localizedLanguageName(_ code: String, fallback: String) -> String {
        guard settings.isPolish else { return fallback }
        let names: [String: String] = [
            "auto":"Wykryj automatycznie", "pl":"Polski", "en":"Angielski", "de":"Niemiecki", "es":"Hiszpański", "fr":"Francuski", "it":"Włoski", "pt":"Portugalski", "uk":"Ukraiński", "ru":"Rosyjski", "cs":"Czeski", "sk":"Słowacki", "nl":"Niderlandzki", "sv":"Szwedzki", "no":"Norweski", "da":"Duński", "fi":"Fiński", "tr":"Turecki", "el":"Grecki", "hu":"Węgierski", "ro":"Rumuński", "bg":"Bułgarski", "hr":"Chorwacki", "sr":"Serbski", "sl":"Słoweński", "lt":"Litewski", "lv":"Łotewski", "et":"Estoński", "ar":"Arabski", "he":"Hebrajski", "hi":"Hindi", "zh":"Chiński", "ja":"Japoński", "ko":"Koreański"
        ]
        return names[code] ?? fallback
    }

    private func clock(_ value: TimeInterval) -> String {
        let s = max(0, Int(value.rounded())); return String(format: "%02d:%02d", s / 60, s % 60)
    }
    private func chooseSource() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false; p.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav]
        if p.runModal() == .OK { source = p.url }
    }
    private func chooseDestination() { let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; if p.runModal() == .OK { destination = p.url } }

    private func startTranscription() {
        guard settings.runtimeMode == .custom || managedRuntime.state.status.isReady else {
            showManagedSetup()
            return
        }
        guard transcriptionTask == nil, !busy else { return }
        let task = Task { await run() }
        transcriptionTask = task
    }

    private func cancelTranscription() {
        guard busy, let transcriptionTask, !transcriptionTask.isCancelled else { return }
        status = settings.tr("Anulowanie…", "Cancelling…")
        transcriptionTask.cancel()
    }

    @MainActor private func run() async {
        guard let source else { return }
        busy = true; status = settings.tr("Analiza pliku…", "Analyzing file…")
        do {
            let runtimePaths = settings.resolvedRuntimePaths
            let duration = try await audioDuration(source, runtimePaths: runtimePaths)
            try Task.checkCancellation()
            progress.start(duration: duration); status = settings.tr("Transkrypcja…", "Transcribing…")
            let result = try await TranscriptionEngine().transcribe(input: source, runtimePaths: runtimePaths, language: sourceLanguage, translateToEnglish: translate && targetLanguage == "en", transcriptionConfig: settings.transcriptionConfig) { line in
                Task { @MainActor in progress.consume(line) }
            }
            try Task.checkCancellation()
            let folder = destination ?? source.deletingLastPathComponent(); let ext = format.rawValue.lowercased()
            let documentTitle = source.deletingPathExtension().lastPathComponent
            let out = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_transcript").appendingPathExtension(ext)
            try TranscriptOutputPublisher.publish(to: out) { stagedOutput in
                switch format {
                case .txt: try txtContent(result, timestamps: timestamps, title: documentTitle, timestampStyle: timestampStyle, timestampSpacing: timestampSpacing).write(to: stagedOutput, atomically: true, encoding: .utf8)
                case .srt: try srtContent(result).write(to: stagedOutput, atomically: true, encoding: .utf8)
                case .pdf:
                    let pdfBody = formattedTranscriptBody(result, timestamps: timestamps, timestampStyle: timestampStyle, timestampSpacing: timestampSpacing)
                    try writePDF(title: documentTitle, text: pdfBody, to: stagedOutput, polishInterface: settings.isPolish, bodyFontSize: CGFloat(documentFontSize))
                }
            }
            progress.finish(); status = settings.tr("Gotowe: ", "Done: ") + out.lastPathComponent; NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch is CancellationError {
            progress.stop()
            status = settings.tr("Anulowano", "Cancelled")
        } catch {
            progress.stop(); errorText = error.localizedDescription; status = settings.tr("Błąd", "Failed")
        }
        busy = false
        transcriptionTask = nil
    }

    private func audioDuration(_ url: URL, runtimePaths: ResolvedRuntimePaths) async throws -> TimeInterval {
        try RuntimeValidator().validateFFmpeg(runtimePaths)
        let cancellation = ProcessCancellationController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            let p = Process(); p.executableURL = runtimePaths.ffmpegExecutableURL; p.arguments = ["-i", url.path]
            let pipe = Pipe(); p.standardError = pipe; p.standardOutput = Pipe()
            p.terminationHandler = { _ in
                cancellation.clear(p)
                if cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let pattern = #"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d{2})"#
                var value = 0.0
                if let r = try? NSRegularExpression(pattern: pattern), let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges == 5 {
                    func n(_ i: Int) -> Double { guard let rr = Range(m.range(at: i), in: text) else { return 0 }; return Double(text[rr]) ?? 0 }
                    value = n(1)*3600 + n(2)*60 + n(3) + n(4)/100
                }
                continuation.resume(returning: value)
            }
                do { try cancellation.launch(p) } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}


struct TimestampOptionsView: View {
    @Binding var style: TimestampDisplayStyle
    @Binding var spacing: TimestampSpacing
    @Binding var fontSize: Double
    let format: OutputFormat
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.spacing) {
            Text(settings.tr("Opcje timestampów", "Timestamp Options"))
                .font(AppTheme.titleFont)

            Picker(settings.tr("Format", "Format"), selection: $style) {
                Text(settings.tr("Tylko początek", "Start only")).tag(TimestampDisplayStyle.startOnly)
                Text(settings.tr("Początek + koniec", "Start + end")).tag(TimestampDisplayStyle.startAndEnd)
            }
            .pickerStyle(.radioGroup)

            Divider()

            Picker(settings.tr("Odstęp", "Spacing"), selection: $spacing) {
                Text(settings.tr("Automatycznie", "Automatic")).tag(TimestampSpacing.automatic)
                Text(settings.tr("Co około 15 sekund", "About every 15 seconds")).tag(TimestampSpacing.seconds15)
                Text(settings.tr("Co około 30 sekund", "About every 30 seconds")).tag(TimestampSpacing.seconds30)
                Text(settings.tr("Co około 60 sekund", "About every 60 seconds")).tag(TimestampSpacing.seconds60)
            }
            .pickerStyle(.radioGroup)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(settings.tr("Rozmiar tekstu PDF", "PDF text size"))
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $fontSize, in: 8...14, step: 1)
                    .disabled(format != .pdf)

                if format == .txt {
                    Text(settings.tr(
                        "Plik TXT nie zapisuje informacji o kroju ani rozmiarze fontu. Rozmiar tekstu zależy od programu, w którym otwierasz plik.",
                        "TXT files do not store font family or font size. Text size depends on the app used to open the file."
                    ))
                    .font(AppTheme.secondaryFont)
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text(settings.tr(
                "Większe odstępy łączą kolejne segmenty Whispera w dłuższe bloki tekstu. Timestamp wskazuje początek (lub początek i koniec) całego bloku.",
                "Larger spacing merges consecutive Whisper segments into longer text blocks. The timestamp marks the start (or start and end) of the whole block."
            ))
            .font(AppTheme.secondaryFont)
            .foregroundStyle(.secondary)
            .frame(width: 330, alignment: .leading)
        }
        .font(AppTheme.bodyFont)
        .controlSize(.small)
        .padding(14)
        .frame(width: 370)
        .background(AppTheme.surface)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
    }
}

struct TranscriptionDetailsContent: View {
    @ObservedObject var progress: TranscriptionProgress
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(progress.details.isEmpty
                     ? settings.tr("Gotowy do transkrypcji.", "Ready for transcription.")
                     : progress.details)
                    .font(progress.details.isEmpty ? AppTheme.secondaryFont : AppTheme.monospacedFont)
                    .foregroundStyle(progress.details.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("details-bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: progress.details) { _, _ in
                proxy.scrollTo("details-bottom", anchor: .bottom)
            }
        }
    }
}
