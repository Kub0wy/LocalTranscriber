import Foundation
import Darwin

private func appText(_ pl: String, _ en: String) -> String {
    (UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "en") == "pl" ? pl : en
}

struct Segment: Codable {
    let start: Double
    let end: Double
    let text: String
}

struct WorkerResult: Codable {
    let text: String
    let segments: [Segment]
}

enum TranscriptOutputPublisher {
    /// Builds an output beside its destination, then exposes it only after the
    /// task has passed the final cancellation boundary.
    static func publish(to destination: URL, writer: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-transcript")
            .appendingPathExtension(destination.pathExtension)
        defer { try? FileManager.default.removeItem(at: staged) }

        try writer(staged)
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case txt = "TXT"
    case srt = "SRT"
    case pdf = "PDF"
    var id: String { rawValue }
}

enum TranscriptionError: LocalizedError {
    case invalidSettings(String)
    case workerFailed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let s): return s
        case .workerFailed(let s): return s
        case .badOutput: return appText("Nie udało się odczytać wyniku transkrypcji.", "Could not read the transcription result.")
        }
    }
}

final class LockedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        let parts = pending.components(separatedBy: .newlines)
        pending = parts.last ?? ""
        return Array(parts.dropLast()).filter { !$0.isEmpty }
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }
}

/// Owns the worker process for one transcription and bridges structured Swift
/// cancellation to the external Python backend.
final class ProcessCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func launch(_ process: Process) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()

        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()

        // A backend stuck in native code may ignore SIGTERM. Do not leave an
        // orphan process behind after its owning task/window disappears.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            guard runningProcess.isRunning else { return }
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }

    func clear(_ completedProcess: Process) {
        lock.lock()
        if process === completedProcess { process = nil }
        lock.unlock()
    }
}

final class TranscriptionEngine {
    private let workerURL: URL?
    private let temporaryDirectory: URL

    init(workerURL: URL? = nil, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.workerURL = workerURL
        self.temporaryDirectory = temporaryDirectory
    }

    func transcribe(
        input: URL,
        runtimePaths: ResolvedRuntimePaths,
        language: String,
        translateToEnglish: Bool,
        transcriptionConfig: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerResult {
        try RuntimeValidator().validateExecutables(runtimePaths)
        guard let worker = workerURL ?? Bundle.main.url(forResource: "transcribe_worker", withExtension: "py") else {
            throw TranscriptionError.invalidSettings(appText("Brakuje składnika transkrypcji w aplikacji. Zainstaluj ponownie LocalTranscriber.", "A transcription component is missing from the app. Reinstall LocalTranscriber."))
        }

        let resolvedModelPath = try resolveModelPath(runtimePaths.modelDirectoryURL)
        try Task.checkCancellation()

        let temp = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let process = Process()
        process.executableURL = runtimePaths.pythonExecutableURL
        let configTemp = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        guard let configData = transcriptionConfig.data(using: .utf8) else {
            throw TranscriptionError.invalidSettings(appText("Nie można zapisać konfiguracji transkrypcji.", "Could not save transcription configuration."))
        }
        do {
            let object = try JSONSerialization.jsonObject(with: configData)
            guard object is [String: Any] else { throw TranscriptionError.invalidSettings(appText("Konfiguracja musi być obiektem JSON { ... }.", "Config must be a JSON object { ... }.")) }
            try configData.write(to: configTemp)
        } catch let e as TranscriptionError { throw e }
          catch { throw TranscriptionError.invalidSettings(appText("Błędna konfiguracja JSON: \(error.localizedDescription)", "Invalid JSON config: \(error.localizedDescription)")) }

        process.arguments = [worker.path, "--input", input.path, "--output", temp.path, "--model", resolvedModelPath, "--language", language, "--task", translateToEnglish ? "translate" : "transcribe", "--config", configTemp.path]

        var env = ProcessInfo.processInfo.environment
        let ffDir = runtimePaths.ffmpegExecutableURL.deletingLastPathComponent().path
        env["PATH"] = ffDir + ":" + (env["PATH"] ?? "")
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let lineBuffer = LockedLineBuffer()
        let cancellation = ProcessCancellationController()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            guard !cancellation.isCancelled else { return }
            for line in lineBuffer.append(chunk) where !cancellation.isCancelled { onLine(line) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { p in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    cancellation.clear(p)
                    defer {
                        try? FileManager.default.removeItem(at: temp)
                        try? FileManager.default.removeItem(at: configTemp)
                    }
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        if p.terminationStatus != 0 {
                            let tail = lineBuffer.tail()
                            if tail.localizedCaseInsensitiveContains("mlx_whisper") && tail.localizedCaseInsensitiveContains("module") {
                                throw TranscriptionError.workerFailed(appText(
                                    "Pakiet mlx-whisper jest niedostępny w wybranym środowisku Python. Wybierz inne środowisko w Ustawieniach.",
                                    "mlx-whisper is not available in the selected Python environment. Choose another environment in Settings."
                                ))
                            }
                            throw TranscriptionError.workerFailed(tail.isEmpty ? appText("Proces mlx-whisper zakończył się błędem.", "The mlx-whisper process failed.") : tail)
                        }
                        try Task.checkCancellation()
                        let data = try Data(contentsOf: temp)
                        try Task.checkCancellation()
                        continuation.resume(returning: try JSONDecoder().decode(WorkerResult.self, from: data))
                    } catch { continuation.resume(throwing: error) }
                }
                do {
                    try cancellation.launch(process)
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    try? FileManager.default.removeItem(at: temp)
                    try? FileManager.default.removeItem(at: configTemp)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    private func resolveModelPath(_ configuredURL: URL) throws -> String {
        let fm = FileManager.default
        try RuntimeValidator().validateModelDirectory(configuredURL)
        let configuredPath = configuredURL.path

        // If Settings already points directly at a model snapshot, use it.
        if fm.fileExists(atPath: (configuredPath as NSString).appendingPathComponent("config.json")) {
            return configuredPath
        }

        // Settings may point at the Hugging Face cache root, the model directory,
        // or its snapshots directory. Find snapshots that contain config.json.
        guard let enumerator = fm.enumerator(
            at: configuredURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw RuntimeValidationError(component: .model)
        }

        var candidates: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "config.json" else { continue }
            let folder = url.deletingLastPathComponent()
            let path = folder.path

            // Avoid accidentally selecting an unrelated model if the cache grows later.
            let looksLikeWhisper = path.localizedCaseInsensitiveContains("whisper")
            let looksLikeSnapshot = path.contains("/snapshots/")
            guard looksLikeWhisper && looksLikeSnapshot else { continue }

            let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
            candidates.append((folder, values?.contentModificationDate ?? .distantPast))
        }

        guard let best = candidates.max(by: { $0.date < $1.date }) else {
            throw RuntimeValidationError(component: .model)
        }
        return best.url.path
    }

    /// Compatibility entry point for callers that already supply individual
    /// paths. Resolution still passes through the centralized runtime layer.
    func transcribe(
        input: URL,
        pythonPath: String,
        ffmpegPath: String,
        modelPath: String,
        language: String,
        translateToEnglish: Bool,
        transcriptionConfig: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> WorkerResult {
        let configuration = RuntimeConfiguration(
            mode: .custom,
            customPythonPath: pythonPath,
            customFFmpegPath: ffmpegPath,
            customModelPath: modelPath
        )
        return try await transcribe(
            input: input,
            runtimePaths: RuntimePathResolver().resolve(configuration),
            language: language,
            translateToEnglish: translateToEnglish,
            transcriptionConfig: transcriptionConfig,
            onLine: onLine
        )
    }

}
