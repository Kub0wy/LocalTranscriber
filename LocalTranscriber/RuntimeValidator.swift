import Foundation

enum RuntimeComponent: Sendable {
    case python
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

struct RuntimeValidator {
    func validateExecutables(_ paths: ResolvedRuntimePaths) throws {
        guard FileManager.default.isExecutableFile(atPath: paths.pythonExecutableURL.path) else {
            throw RuntimeValidationError(component: .python)
        }
        guard FileManager.default.isExecutableFile(atPath: paths.ffmpegExecutableURL.path) else {
            throw RuntimeValidationError(component: .ffmpeg)
        }
    }

    func validateFFmpeg(_ paths: ResolvedRuntimePaths) throws {
        guard FileManager.default.isExecutableFile(atPath: paths.ffmpegExecutableURL.path) else {
            throw RuntimeValidationError(component: .ffmpeg)
        }
    }

    func validateModelDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeValidationError(component: .model)
        }
    }
}
