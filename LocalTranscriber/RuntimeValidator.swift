import Foundation

enum RuntimeComponent: Sendable {
    case python
    case mlxWhisper
    case ffmpeg
    case model
}

struct RuntimeValidationError: LocalizedError, Sendable {
    let component: RuntimeComponent

    var errorDescription: String? {
        let isPolish = (UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "en") == "pl"
        switch (component, isPolish) {
        case (.python, true):
            return "Środowisko Python jest niedostępne. Otwórz Ustawienia, aby wybrać istniejącą instalację Pythona."
        case (.python, false):
            return "The Python runtime is not available. Open Settings to select an existing Python installation."
        case (.mlxWhisper, true):
            return "Nie można zaimportować mlx-whisper w wybranym środowisku Python. Zainstaluj pakiet w tym środowisku lub wybierz inny plik Python w Ustawieniach."
        case (.mlxWhisper, false):
            return "Cannot import mlx-whisper in the selected Python environment. Install the package in that environment or choose another Python executable in Settings."
        case (.ffmpeg, true):
            return "FFmpeg jest niedostępny. Otwórz Ustawienia, aby wybrać istniejący plik wykonywalny FFmpeg."
        case (.ffmpeg, false):
            return "FFmpeg is not available. Open Settings to select an existing FFmpeg executable."
        case (.model, true):
            return "Model Whisper jest niedostępny. Otwórz Ustawienia, aby wybrać istniejący katalog modelu."
        case (.model, false):
            return "The Whisper model is not available. Open Settings to select an existing model directory."
        }
    }
}

struct RuntimeValidator: Sendable {
    /// Injectable so validation tests never require an installed MLX environment.
    var runProcess: @Sendable (URL, [String]) throws -> Int32 = { try Self.launchProcess($0, $1) }

    private static func launchProcess(_ executable: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Imports can emit arbitrary diagnostics; avoid filling an unread pipe.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw CocoaError(.executableRuntimeMismatch)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func validateExecutables(_ paths: ResolvedRuntimePaths) throws {
        try validatePython(paths)
        try validateFFmpeg(paths)
    }

    func validatePython(_ paths: ResolvedRuntimePaths) throws {
        let python = paths.pythonExecutableURL
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw RuntimeValidationError(component: .python)
        }
        do {
            guard try runProcess(python, ["--version"]) == 0 else {
                throw RuntimeValidationError(component: .python)
            }
        } catch {
            throw RuntimeValidationError(component: .python)
        }
        do {
            guard try runProcess(python, ["-c", "import mlx_whisper"]) == 0 else {
                throw RuntimeValidationError(component: .mlxWhisper)
            }
        } catch {
            throw RuntimeValidationError(component: .mlxWhisper)
        }
    }

    /// Check every component even when another component fails.
    func validationErrors(_ paths: ResolvedRuntimePaths) -> [RuntimeValidationError] {
        var errors: [RuntimeValidationError] = []
        for check in [
            { try validatePython(paths) },
            { try validateFFmpeg(paths) },
            { _ = try resolveModelPath(paths.modelDirectoryURL) }
        ] {
            do { try check() }
            catch let error as RuntimeValidationError { errors.append(error) }
            catch { errors.append(RuntimeValidationError(component: .model)) }
        }
        return errors
    }

    func validateFFmpeg(_ paths: ResolvedRuntimePaths) throws {
        guard FileManager.default.isExecutableFile(atPath: paths.ffmpegExecutableURL.path) else {
            throw RuntimeValidationError(component: .ffmpeg)
        }
        do {
            guard try runProcess(paths.ffmpegExecutableURL, ["-version"]) == 0 else {
                throw RuntimeValidationError(component: .ffmpeg)
            }
        } catch {
            throw RuntimeValidationError(component: .ffmpeg)
        }
    }

    func validateModelDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeValidationError(component: .model)
        }
    }

    func resolveModelPath(_ configuredURL: URL) throws -> String {
        let fm = FileManager.default
        try validateModelDirectory(configuredURL)
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
}
