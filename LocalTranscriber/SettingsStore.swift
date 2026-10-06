import Foundation

struct WhisperLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let defaultInterfaceLanguage = "en"

    static let languages: [WhisperLanguage] = [
        .init(code: "auto", name: "Auto Detect"), .init(code: "pl", name: "Polish"),
        .init(code: "en", name: "English"), .init(code: "de", name: "German"),
        .init(code: "es", name: "Spanish"), .init(code: "fr", name: "French"),
        .init(code: "it", name: "Italian"), .init(code: "pt", name: "Portuguese"),
        .init(code: "uk", name: "Ukrainian"), .init(code: "ru", name: "Russian"),
        .init(code: "cs", name: "Czech"), .init(code: "sk", name: "Slovak"),
        .init(code: "nl", name: "Dutch"), .init(code: "sv", name: "Swedish"),
        .init(code: "no", name: "Norwegian"), .init(code: "da", name: "Danish"),
        .init(code: "fi", name: "Finnish"), .init(code: "tr", name: "Turkish"),
        .init(code: "el", name: "Greek"), .init(code: "hu", name: "Hungarian"),
        .init(code: "ro", name: "Romanian"), .init(code: "bg", name: "Bulgarian"),
        .init(code: "hr", name: "Croatian"), .init(code: "sr", name: "Serbian"),
        .init(code: "sl", name: "Slovenian"), .init(code: "lt", name: "Lithuanian"),
        .init(code: "lv", name: "Latvian"), .init(code: "et", name: "Estonian"),
        .init(code: "ar", name: "Arabic"), .init(code: "he", name: "Hebrew"),
        .init(code: "hi", name: "Hindi"), .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"), .init(code: "ko", name: "Korean")
    ]

    static let defaultTranscriptionConfig = """
    {
      "condition_on_previous_text": false,
      "temperature": 0.0
    }
    """

    @Published var runtimeMode: RuntimeMode { didSet { save() } }
    @Published var modelPath: String { didSet { save() } }
    @Published var pythonPath: String { didSet { save() } }
    @Published var ffmpegPath: String { didSet { save() } }
    @Published var managedInstallPath: String { didSet { save() } }
    @Published var transcriptionConfig: String { didSet { save() } }
    @Published var interfaceLanguage: String { didSet { save() } }

    var isPolish: Bool { interfaceLanguage == "pl" }
    func tr(_ pl: String, _ en: String) -> String { isPolish ? pl : en }

    var runtimeConfiguration: RuntimeConfiguration {
        RuntimeConfiguration(
            mode: runtimeMode,
            customPythonPath: pythonPath,
            customFFmpegPath: ffmpegPath,
            customModelPath: modelPath,
            managedInstallPath: managedInstallPath
        )
    }

    var resolvedRuntimePaths: ResolvedRuntimePaths {
        RuntimePathResolver().resolve(runtimeConfiguration)
    }

    private init() {
        let d = UserDefaults.standard
        let existingModelPath = d.string(forKey: "modelPath") ?? ""
        let existingPythonPath = d.string(forKey: "pythonPath") ?? ""
        let existingFFmpegPath = d.string(forKey: "ffmpegPath") ?? ""
        let hasLegacyCustomPaths = !existingModelPath.isEmpty || !existingPythonPath.isEmpty || !existingFFmpegPath.isEmpty
        runtimeMode = d.string(forKey: "runtimeMode").flatMap(RuntimeMode.init(rawValue:))
            ?? (hasLegacyCustomPaths ? .custom : .managed)
        modelPath = existingModelPath
        pythonPath = existingPythonPath
        ffmpegPath = existingFFmpegPath
        managedInstallPath = d.string(forKey: "managedInstallPath") ?? ""
        transcriptionConfig = d.string(forKey: "transcriptionConfig") ?? Self.defaultTranscriptionConfig
        interfaceLanguage = d.string(forKey: "interfaceLanguage") ?? Self.defaultInterfaceLanguage
    }

    func resetConfig() { transcriptionConfig = Self.defaultTranscriptionConfig }

    func configValidationError() -> String? {
        guard let data = transcriptionConfig.data(using: .utf8) else { return tr("Nie można odczytać konfiguracji.", "Could not read configuration.") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else { return tr("Konfiguracja musi być obiektem JSON { ... }.", "Config must be a JSON object { ... }.") }
            return nil
        } catch { return error.localizedDescription }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(runtimeMode.rawValue, forKey: "runtimeMode")
        d.set(modelPath, forKey: "modelPath"); d.set(pythonPath, forKey: "pythonPath")
        d.set(ffmpegPath, forKey: "ffmpegPath"); d.set(transcriptionConfig, forKey: "transcriptionConfig")
        d.set(managedInstallPath, forKey: "managedInstallPath")
        d.set(interfaceLanguage, forKey: "interfaceLanguage")
    }
}
