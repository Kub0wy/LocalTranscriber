import Foundation

enum RuntimeMode: String, CaseIterable, Identifiable, Sendable {
    case managed
    case custom

    var id: String { rawValue }
}

/// Persisted runtime choices. Empty custom paths deliberately fall back to the
/// managed location so each component can be overridden independently.
struct RuntimeConfiguration: Equatable, Sendable {
    var mode: RuntimeMode
    var customPythonPath: String
    var customFFmpegPath: String
    var customModelPath: String
}

struct ResolvedRuntimePaths: Equatable, Sendable {
    let pythonExecutableURL: URL
    let ffmpegExecutableURL: URL
    let ffprobeExecutableURL: URL
    let modelDirectoryURL: URL
    let runtimeDirectoryURL: URL
}

struct RuntimePathResolver {
    private let applicationSupportDirectory: URL

    init(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    func resolve(_ configuration: RuntimeConfiguration) -> ResolvedRuntimePaths {
        let appDirectory = applicationSupportDirectory
            .appendingPathComponent("LocalTranscriber", isDirectory: true)
        let runtimeDirectory = appDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let managedPython = runtimeDirectory
            .appendingPathComponent("Environment", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
        let managedFFmpegDirectory = runtimeDirectory.appendingPathComponent("FFmpeg", isDirectory: true)
        let managedFFmpeg = managedFFmpegDirectory.appendingPathComponent("ffmpeg")
        let managedModelDirectory = appDirectory.appendingPathComponent("Models", isDirectory: true)

        let usesCustomPaths = configuration.mode == .custom
        let python = overrideURL(configuration.customPythonPath, enabled: usesCustomPaths) ?? managedPython
        let ffmpeg = overrideURL(configuration.customFFmpegPath, enabled: usesCustomPaths) ?? managedFFmpeg
        let model = overrideURL(configuration.customModelPath, enabled: usesCustomPaths) ?? managedModelDirectory

        return ResolvedRuntimePaths(
            pythonExecutableURL: python,
            ffmpegExecutableURL: ffmpeg,
            ffprobeExecutableURL: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            modelDirectoryURL: model,
            runtimeDirectoryURL: runtimeDirectory
        )
    }

    private func overrideURL(_ path: String, enabled: Bool) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }
}
